package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/fsnotify/fsnotify"
)

type server struct {
	agentDir     string
	token        string
	piExecutable string

	mu           sync.RWMutex
	lastRefresh  time.Time
	snapshot     catalogResponse
	sessionsByID map[string]sessionRecord

	broker *catalogBroker
}

type catalogResponse struct {
	Projects []projectRecord `json:"projects"`
	Sessions []sessionRecord `json:"sessions"`
}

type projectRecord struct {
	ID               string     `json:"id"`
	Title            string     `json:"title"`
	WorkingDirectory string     `json:"workingDirectory,omitempty"`
	SessionDirectory string     `json:"sessionDirectory"`
	SessionCount     int        `json:"sessionCount"`
	LastActivity     *time.Time `json:"lastActivity,omitempty"`
}

type sessionRecord struct {
	ID                 string    `json:"id"`
	FilePath           string    `json:"filePath"`
	ProjectID          string    `json:"projectID"`
	Title              string    `json:"title"`
	WorkingDirectory   string    `json:"workingDirectory,omitempty"`
	MessageCount       int       `json:"messageCount"`
	ModifiedAt         time.Time `json:"modifiedAt"`
	DisplayName        string    `json:"displayName,omitempty"`
	ParentSession      string    `json:"parentSession,omitempty"`
	BranchCount        int       `json:"branchCount"`
	LabelCount         int       `json:"labelCount"`
	BranchSummaryCount int       `json:"branchSummaryCount"`
	LatestModel        string    `json:"latestModel,omitempty"`
}

type eventsResponse struct {
	Events []rawEventRecord `json:"events"`
	Page   pageRecord       `json:"page"`
}

type rawEventRecord struct {
	Line int    `json:"line"`
	Raw  string `json:"raw"`
}

type pageRecord struct {
	FirstLine     int  `json:"firstLine"`
	LastLine      int  `json:"lastLine"`
	HasMoreBefore bool `json:"hasMoreBefore"`
	HasMoreAfter  bool `json:"hasMoreAfter"`
}

type fileListResponse struct {
	Path   string           `json:"path"`
	Parent string           `json:"parent,omitempty"`
	Items  []fileItemRecord `json:"items"`
}

type fileItemRecord struct {
	Name        string     `json:"name"`
	Path        string     `json:"path"`
	IsDirectory bool       `json:"isDirectory"`
	Size        int64      `json:"size,omitempty"`
	ModifiedAt  *time.Time `json:"modifiedAt,omitempty"`
}

type attachmentReference struct {
	Path     string `json:"path"`
	FileName string `json:"fileName,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
	Size     int64  `json:"size,omitempty"`
}

type createSessionRequest struct {
	WorkingDirectory string                `json:"workingDirectory"`
	SessionName      string                `json:"sessionName"`
	IsTemporary      bool                  `json:"isTemporary"`
	Prompt           string                `json:"prompt"`
	ForkPath         string                `json:"forkPath"`
	Attachments      []attachmentReference `json:"attachments"`
}

type sendSessionRequest struct {
	Prompt      string                `json:"prompt"`
	Attachments []attachmentReference `json:"attachments"`
}

type sessionBoundRecord struct {
	Type             string `json:"type"`
	SessionID        string `json:"sessionId,omitempty"`
	FilePath         string `json:"filePath,omitempty"`
	Title            string `json:"title,omitempty"`
	WorkingDirectory string `json:"workingDirectory,omitempty"`
}

type uploadResponse struct {
	Path     string `json:"path"`
	FileName string `json:"fileName"`
	MimeType string `json:"mimeType,omitempty"`
	Size     int64  `json:"size,omitempty"`
}

type streamErrorRecord struct {
	Type  string `json:"type"`
	Error string `json:"error"`
}

type rpcImageContent struct {
	Type     string `json:"type"`
	Data     string `json:"data"`
	MimeType string `json:"mimeType"`
}

type rpcPromptCommand struct {
	ID                string            `json:"id,omitempty"`
	Type              string            `json:"type"`
	Message           string            `json:"message"`
	Images            []rpcImageContent `json:"images,omitempty"`
	StreamingBehavior string            `json:"streamingBehavior,omitempty"`
}

type rpcGetStateCommand struct {
	ID   string `json:"id,omitempty"`
	Type string `json:"type"`
}

type rpcStateResponse struct {
	Type    string `json:"type"`
	Command string `json:"command"`
	Success bool   `json:"success"`
	Data    *struct {
		SessionFile string `json:"sessionFile"`
		SessionID   string `json:"sessionId"`
		SessionName string `json:"sessionName"`
	} `json:"data"`
}

type parsedSession struct {
	ID                 string
	WorkingDirectory   string
	DisplayName        string
	FirstUserMessage   string
	MessageCount       int
	ParentSession      string
	BranchCount        int
	LabelCount         int
	BranchSummaryCount int
	LatestModel        string
}

type statusRecorder struct {
	http.ResponseWriter
	statusCode int
}

func (r *statusRecorder) WriteHeader(statusCode int) {
	r.statusCode = statusCode
	r.ResponseWriter.WriteHeader(statusCode)
}

// Flush forwards to the underlying ResponseWriter when it supports flushing.
// This lets streaming handlers (SSE, NDJSON) work through the logging middleware.
func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func main() {
	agentDir := getenvDefault("PI_APPD_AGENT_DIR", "~/.pi/agent")
	addr := getenvDefault("PI_APPD_ADDR", "127.0.0.1:8787")
	token := strings.TrimSpace(os.Getenv("PI_APPD_TOKEN"))
	piExecutable := getenvDefault("PI_APPD_PI_EXECUTABLE", "pi")

	srv := &server{
		agentDir:     expandHome(agentDir),
		token:        token,
		piExecutable: piExecutable,
		sessionsByID: map[string]sessionRecord{},
		broker:       newCatalogBroker(),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealthz)
	mux.HandleFunc("/sessions", srv.handleSessions)
	mux.HandleFunc("/sessions/", srv.handleSessionSubroutes)
	mux.HandleFunc("/files", srv.handleFiles)
	mux.HandleFunc("/uploads", srv.handleUploads)

	go srv.watchCatalog()

	log.Printf("pi-appd listening on %s (agentDir=%s)", addr, srv.agentDir)
	if err := http.ListenAndServe(addr, srv.loggingMiddleware(srv.authMiddleware(mux))); err != nil {
		log.Fatal(err)
	}
}

func (s *server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.token != "" {
			auth := strings.TrimSpace(r.Header.Get("Authorization"))
			if auth != "Bearer "+s.token {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		writer := &statusRecorder{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(writer, r)
		log.Printf("%s %s -> %d (%s) from %s", r.Method, r.URL.RequestURI(), writer.statusCode, time.Since(started).Round(time.Millisecond), r.RemoteAddr)
	})
}

func (s *server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleSessions(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/sessions" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		if err := s.refreshCatalogIfNeeded(); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		s.mu.RLock()
		defer s.mu.RUnlock()
		writeJSON(w, http.StatusOK, s.snapshot)
	case http.MethodPost:
		s.handleCreateSession(w, r)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *server) handleSessionSubroutes(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/sessions/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || strings.TrimSpace(parts[0]) == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	// /sessions/stream is a top-level subroute and does not require a session lookup.
	if parts[0] == "stream" && (len(parts) == 1 || parts[1] == "") {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionsStream(w, r)
		return
	}
	sessionID := parts[0]
	if err := s.refreshCatalogIfNeeded(); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.mu.RLock()
	record, ok := s.sessionsByID[sessionID]
	s.mu.RUnlock()
	if !ok {
		writeError(w, http.StatusNotFound, "unknown session")
		return
	}
	if len(parts) == 1 {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		writeJSON(w, http.StatusOK, record)
		return
	}
	if len(parts) == 2 && parts[1] == "events" {
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionEvents(w, r, record)
		return
	}
	if len(parts) == 2 && parts[1] == "send" {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		s.handleSessionSend(w, r, record)
		return
	}
	writeError(w, http.StatusNotFound, "not found")
}

func (s *server) handleSessionEvents(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	before, hasBefore, err := optionalInt(r.URL.Query().Get("before"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid before")
		return
	}
	after, hasAfter, err := optionalInt(r.URL.Query().Get("after"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid after")
		return
	}
	limit := 0
	if !hasBefore && !hasAfter {
		limit = 120
	}
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 0 {
			writeError(w, http.StatusBadRequest, "invalid limit")
			return
		}
	}

	if !hasBefore && !hasAfter {
		lines, totalLines, err := readLastLines(record.FilePath, limit)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		startLine := totalLines - len(lines)
		if startLine < 0 {
			startLine = 0
		}
		events := make([]rawEventRecord, 0, len(lines))
		for i, line := range lines {
			events = append(events, rawEventRecord{Line: startLine + i, Raw: line})
		}
		page := pageRecord{HasMoreBefore: startLine > 0, HasMoreAfter: false}
		if len(events) > 0 {
			page.FirstLine = events[0].Line
			page.LastLine = events[len(events)-1].Line
		}
		writeJSON(w, http.StatusOK, eventsResponse{Events: events, Page: page})
		return
	}

	lines, err := readAllLines(record.FilePath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	start, end := 0, len(lines)
	hasMoreBefore, hasMoreAfter := false, false
	if hasBefore {
		if before < 0 {
			before = 0
		}
		if before > len(lines) {
			before = len(lines)
		}
		end = before
		if limit > 0 && end-limit > 0 {
			start = end - limit
			hasMoreBefore = start > 0
		} else {
			start = 0
			hasMoreBefore = false
		}
		hasMoreAfter = end < len(lines)
	} else if hasAfter {
		if after < -1 {
			after = -1
		}
		start = after + 1
		if start < 0 {
			start = 0
		}
		if start > len(lines) {
			start = len(lines)
		}
		end = len(lines)
		hasMoreBefore = start > 0
		hasMoreAfter = false
	} else if limit > 0 && limit < len(lines) {
		start = len(lines) - limit
		hasMoreBefore = start > 0
	}

	events := make([]rawEventRecord, 0, end-start)
	for i := start; i < end; i++ {
		events = append(events, rawEventRecord{Line: i, Raw: lines[i]})
	}
	page := pageRecord{HasMoreBefore: hasMoreBefore, HasMoreAfter: hasMoreAfter}
	if len(events) > 0 {
		page.FirstLine = events[0].Line
		page.LastLine = events[len(events)-1].Line
	}
	writeJSON(w, http.StatusOK, eventsResponse{Events: events, Page: page})
}

func (s *server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var request createSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if request.IsTemporary {
		writeError(w, http.StatusBadRequest, "temporary sessions are not supported yet")
		return
	}
	prompt := strings.TrimSpace(request.Prompt)
	if prompt == "" {
		writeError(w, http.StatusBadRequest, "prompt is required")
		return
	}
	cwd := strings.TrimSpace(request.WorkingDirectory)
	if cwd == "" {
		cwd = os.Getenv("HOME")
	}
	cwd = expandHome(cwd)

	rpcPrompt, err := s.buildRPCPromptPayload(prompt, request.Attachments)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	args := []string{"--mode", "rpc"}
	if strings.TrimSpace(request.ForkPath) != "" {
		args = append(args, "--fork", expandHome(request.ForkPath))
	} else if strings.TrimSpace(request.SessionName) != "" {
		args = append(args, "--name", strings.TrimSpace(request.SessionName))
	}

	title := firstNonBlank(strings.TrimSpace(request.SessionName), filepath.Base(cwd), "Pi")
	if err := s.streamPiRPCCommand(w, cwd, args, rpcPrompt, nil, title, cwd); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
}

func (s *server) handleSessionSend(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	var request sendSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	prompt := strings.TrimSpace(request.Prompt)
	if prompt == "" {
		writeError(w, http.StatusBadRequest, "prompt is required")
		return
	}
	binding := &sessionBoundRecord{
		Type:             "session_bound",
		SessionID:        record.ID,
		FilePath:         record.FilePath,
		Title:            record.Title,
		WorkingDirectory: record.WorkingDirectory,
	}
	cwd := firstNonBlank(strings.TrimSpace(record.WorkingDirectory), filepath.Dir(record.FilePath), os.Getenv("HOME"))
	rpcPrompt, err := s.buildRPCPromptPayload(prompt, request.Attachments)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	args := []string{"--mode", "rpc", "--session", record.FilePath}
	if err := s.streamPiRPCCommand(w, cwd, args, rpcPrompt, binding, record.Title, record.WorkingDirectory); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
}

func (s *server) handleFiles(w http.ResponseWriter, r *http.Request) {
	requested := strings.TrimSpace(r.URL.Query().Get("path"))
	if requested == "" {
		requested = os.Getenv("HOME")
		if strings.TrimSpace(requested) == "" {
			requested = "."
		}
	}
	path := expandHome(requested)
	entries, err := os.ReadDir(path)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	items := make([]fileItemRecord, 0, len(entries))
	for _, entry := range entries {
		full := filepath.Join(path, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}
		modifiedAt := info.ModTime()
		items = append(items, fileItemRecord{
			Name:        entry.Name(),
			Path:        full,
			IsDirectory: entry.IsDir(),
			Size:        info.Size(),
			ModifiedAt:  &modifiedAt,
		})
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].IsDirectory != items[j].IsDirectory {
			return items[i].IsDirectory
		}
		return strings.ToLower(items[i].Name) < strings.ToLower(items[j].Name)
	})
	parent := filepath.Dir(path)
	if parent == path {
		parent = ""
	}
	writeJSON(w, http.StatusOK, fileListResponse{Path: path, Parent: parent, Items: items})
}

func (s *server) handleUploads(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "invalid multipart form")
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "file is required")
		return
	}
	defer file.Close()

	uploadDir := filepath.Join(s.agentDir, "uploads")
	if err := os.MkdirAll(uploadDir, 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	fileName := sanitizeUploadName(header.Filename)
	targetPath := filepath.Join(uploadDir, uniqueUploadName(fileName))
	targetFile, err := os.Create(targetPath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer targetFile.Close()

	size, err := io.Copy(targetFile, file)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, uploadResponse{
		Path:     targetPath,
		FileName: filepath.Base(targetPath),
		MimeType: header.Header.Get("Content-Type"),
		Size:     size,
	})
}

func (s *server) buildRPCPromptPayload(prompt string, attachments []attachmentReference) (rpcPromptCommand, error) {
	prefix := strings.Builder{}
	images := make([]rpcImageContent, 0, len(attachments))
	resolved, err := s.resolveAttachmentPaths(attachments)
	if err != nil {
		return rpcPromptCommand{}, err
	}

	for _, attachment := range resolved {
		data, readErr := os.ReadFile(attachment.Path)
		if readErr != nil {
			return rpcPromptCommand{}, errors.New("attachment file does not exist")
		}

		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(attachment.MimeType)), "image/") {
			images = append(images, rpcImageContent{
				Type:     "image",
				Data:     base64.StdEncoding.EncodeToString(data),
				MimeType: attachment.MimeType,
			})
			prefix.WriteString("<file name=\"")
			prefix.WriteString(xmlEscape(attachment.Path))
			prefix.WriteString("\"></file>\n")
			continue
		}

		if len(data) <= 200000 && utf8.Valid(data) && !bytes.Contains(data, []byte{0}) {
			prefix.WriteString("<file name=\"")
			prefix.WriteString(xmlEscape(attachment.Path))
			prefix.WriteString("\">\n")
			prefix.Write(data)
			prefix.WriteString("\n</file>\n")
			continue
		}

		fallback := "[Binary file attached: " + firstNonBlank(attachment.FileName, filepath.Base(attachment.Path), "attachment") + "]"
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(attachment.MimeType)), "audio/") {
			fallback = "[Audio attachment: " + firstNonBlank(attachment.FileName, filepath.Base(attachment.Path), "audio") + "]"
		}
		prefix.WriteString("<file name=\"")
		prefix.WriteString(xmlEscape(attachment.Path))
		prefix.WriteString("\">")
		prefix.WriteString(xmlEscape(fallback))
		prefix.WriteString("</file>\n")
	}

	message := prompt
	if prefix.Len() > 0 {
		message = prefix.String() + "\n" + prompt
	}
	return rpcPromptCommand{
		ID:      "pi-appd-prompt",
		Type:    "prompt",
		Message: message,
		Images:  images,
	}, nil
}

func (s *server) resolveAttachmentPaths(attachments []attachmentReference) ([]attachmentReference, error) {
	if len(attachments) == 0 {
		return nil, nil
	}
	allowedRoot := filepath.Clean(filepath.Join(s.agentDir, "uploads"))
	resolved := make([]attachmentReference, 0, len(attachments))
	for _, attachment := range attachments {
		pathValue, err := filepath.Abs(expandHome(strings.TrimSpace(attachment.Path)))
		if err != nil {
			return nil, errors.New("invalid attachment path")
		}
		pathValue = filepath.Clean(pathValue)
		if !strings.HasPrefix(pathValue, allowedRoot+string(os.PathSeparator)) && pathValue != allowedRoot {
			return nil, errors.New("attachment path is outside uploads directory")
		}
		if _, err := os.Stat(pathValue); err != nil {
			return nil, errors.New("attachment file does not exist")
		}
		attachment.Path = pathValue
		resolved = append(resolved, attachment)
	}
	return resolved, nil
}

func (s *server) streamPiRPCCommand(
	w http.ResponseWriter,
	cwd string,
	args []string,
	prompt rpcPromptCommand,
	binding *sessionBoundRecord,
	fallbackTitle string,
	fallbackWorkingDirectory string,
) error {
	cmd := exec.Command(s.piExecutable, args...)
	cmd.Dir = expandHome(cwd)
	cmd.Env = append(os.Environ(), "PI_CODING_AGENT_DIR="+s.agentDir)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}

	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)
	if binding != nil {
		writeNDJSON(w, binding)
		if flusher != nil {
			flusher.Flush()
		}
	}

	stderrDone := make(chan string, 1)
	go func() {
		data, _ := io.ReadAll(stderr)
		stderrDone <- strings.TrimSpace(string(data))
	}()

	if err := writeRPCCommand(stdin, rpcGetStateCommand{ID: "pi-appd-state", Type: "get_state"}); err != nil {
		writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: err.Error()})
		if flusher != nil {
			flusher.Flush()
		}
		_ = stdin.Close()
		_ = cmd.Wait()
		<-stderrDone
		return nil
	}
	if err := writeRPCCommand(stdin, prompt); err != nil {
		writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: err.Error()})
		if flusher != nil {
			flusher.Flush()
		}
		_ = stdin.Close()
		_ = cmd.Wait()
		<-stderrDone
		return nil
	}

	reader := bufio.NewReader(stdout)
	for {
		line, readErr := reader.ReadBytes('\n')
		if len(line) > 0 {
			rawLine := strings.TrimRight(string(line), "\n")
			if binding == nil {
				if parsedBinding, ok := parseRPCStateBindingLine(rawLine, fallbackTitle, fallbackWorkingDirectory); ok {
					binding = &parsedBinding
					writeNDJSON(w, binding)
					if flusher != nil {
						flusher.Flush()
					}
					continue
				}
			}
			if isRPCResponseLine(rawLine) {
				continue
			}
			_, _ = io.WriteString(w, rawLine)
			_, _ = io.WriteString(w, "\n")
			if flusher != nil {
				flusher.Flush()
			}
			if isAgentEndLine(rawLine) {
				break
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: readErr.Error()})
			if flusher != nil {
				flusher.Flush()
			}
			break
		}
	}

	_ = stdin.Close()
	waitErr := cmd.Wait()
	stderrText := <-stderrDone
	if waitErr != nil {
		message := stderrText
		if message == "" {
			message = waitErr.Error()
		}
		writeNDJSON(w, streamErrorRecord{Type: "stream_error", Error: message})
		if flusher != nil {
			flusher.Flush()
		}
		return nil
	}

	s.refreshAndBroadcast()
	return nil
}

func (s *server) invalidateCatalogSnapshot() {
	s.mu.Lock()
	s.lastRefresh = time.Time{}
	s.snapshot = catalogResponse{}
	s.sessionsByID = map[string]sessionRecord{}
	s.mu.Unlock()
}

func writeRPCCommand(w io.Writer, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if _, err := w.Write(data); err != nil {
		return err
	}
	_, err = w.Write([]byte("\n"))
	return err
}

func parseRPCStateBindingLine(raw string, fallbackTitle string, fallbackWorkingDirectory string) (sessionBoundRecord, bool) {
	var response rpcStateResponse
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &response); err != nil {
		return sessionBoundRecord{}, false
	}
	if response.Type != "response" || response.Command != "get_state" || !response.Success || response.Data == nil {
		return sessionBoundRecord{}, false
	}
	return sessionBoundRecord{
		Type:             "session_bound",
		SessionID:        response.Data.SessionID,
		FilePath:         response.Data.SessionFile,
		Title:            firstNonBlank(strings.TrimSpace(response.Data.SessionName), fallbackTitle),
		WorkingDirectory: firstNonBlank(strings.TrimSpace(fallbackWorkingDirectory), os.Getenv("HOME")),
	}, true
}

func isRPCResponseLine(raw string) bool {
	var object struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &object); err != nil {
		return false
	}
	return object.Type == "response"
}

func isAgentEndLine(raw string) bool {
	var object struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &object); err != nil {
		return false
	}
	return object.Type == "agent_end"
}

func writeNDJSON(w http.ResponseWriter, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_, _ = w.Write(data)
	_, _ = w.Write([]byte("\n"))
}

func (s *server) refreshCatalogIfNeeded() error {
	return s.refreshCatalog(false)
}

func (s *server) refreshCatalog(force bool) error {
	ttl := s.catalogCacheTTL()
	s.mu.RLock()
	fresh := time.Since(s.lastRefresh) < ttl
	s.mu.RUnlock()
	if fresh && !force {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.lastRefresh) < ttl && !force {
		return nil
	}
	catalog, byID, err := buildCatalog(s.agentDir)
	if err != nil {
		return err
	}
	s.snapshot = catalog
	s.sessionsByID = byID
	s.lastRefresh = time.Now()
	return nil
}

func (s *server) catalogCacheTTL() time.Duration {
	if s.broker != nil && s.broker.subscriberCount() > 0 {
		return 10 * time.Second
	}
	return 30 * time.Second
}

func buildCatalog(agentDir string) (catalogResponse, map[string]sessionRecord, error) {
	root := filepath.Join(agentDir, "sessions")
	sessions := make([]sessionRecord, 0, 64)
	byID := map[string]sessionRecord{}

	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		parsed, err := parseSessionFile(path)
		if err != nil {
			return nil
		}
		projectID := filepath.Base(filepath.Dir(path))
		if projectID == "sessions" && strings.TrimSpace(parsed.WorkingDirectory) != "" {
			projectID = encodedProjectID(parsed.WorkingDirectory)
		}
		title := firstNonBlank(parsed.DisplayName, parsed.FirstUserMessage, strings.TrimSuffix(filepath.Base(path), filepath.Ext(path)))
		record := sessionRecord{
			ID:                 firstNonBlank(parsed.ID, strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))),
			FilePath:           path,
			ProjectID:          projectID,
			Title:              title,
			WorkingDirectory:   parsed.WorkingDirectory,
			MessageCount:       parsed.MessageCount,
			ModifiedAt:         info.ModTime().UTC(),
			DisplayName:        parsed.DisplayName,
			ParentSession:      parsed.ParentSession,
			BranchCount:        parsed.BranchCount,
			LabelCount:         parsed.LabelCount,
			BranchSummaryCount: parsed.BranchSummaryCount,
			LatestModel:        parsed.LatestModel,
		}
		sessions = append(sessions, record)
		byID[record.ID] = record
		return nil
	})

	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].ModifiedAt.After(sessions[j].ModifiedAt)
	})
	projects := buildProjects(sessions)
	return catalogResponse{Projects: projects, Sessions: sessions}, byID, nil
}

func buildProjects(sessions []sessionRecord) []projectRecord {
	grouped := map[string][]sessionRecord{}
	for _, session := range sessions {
		grouped[session.ProjectID] = append(grouped[session.ProjectID], session)
	}
	projects := make([]projectRecord, 0, len(grouped))
	for projectID, items := range grouped {
		var last *time.Time
		for _, item := range items {
			if last == nil || item.ModifiedAt.After(*last) {
				value := item.ModifiedAt
				last = &value
			}
		}
		workingDirectory := ""
		if len(items) > 0 {
			workingDirectory = items[0].WorkingDirectory
		}
		projects = append(projects, projectRecord{
			ID:               projectID,
			Title:            projectTitle(projectID, items),
			WorkingDirectory: workingDirectory,
			SessionDirectory: projectID,
			SessionCount:     len(items),
			LastActivity:     last,
		})
	}
	sort.Slice(projects, func(i, j int) bool {
		left := time.Time{}
		right := time.Time{}
		if projects[i].LastActivity != nil {
			left = *projects[i].LastActivity
		}
		if projects[j].LastActivity != nil {
			right = *projects[j].LastActivity
		}
		return left.After(right)
	})
	return projects
}

func parseSessionFile(path string) (parsedSession, error) {
	lines, err := readPreviewLines(path, 80)
	if err != nil {
		return parsedSession{}, err
	}
	return parseSessionLines(lines), nil
}

func parseSessionLines(lines []string) parsedSession {
	result := parsedSession{}
	childCounts := map[string]int{}
	labelTargets := map[string]struct{}{}

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		var object map[string]any
		if err := json.Unmarshal([]byte(trimmed), &object); err != nil {
			continue
		}
		typeValue, _ := object["type"].(string)
		if typeValue == "session" {
			if result.WorkingDirectory == "" {
				result.WorkingDirectory = stringValue(object, "cwd", "workingDirectory")
			}
			if result.ParentSession == "" {
				result.ParentSession = stringValue(object, "parentSession")
			}
			if result.ID == "" {
				result.ID = stringValue(object, "sessionId", "sessionID", "id")
			}
		}
		if result.DisplayName == "" {
			if typeValue == "session_info" || typeValue == "session" {
				result.DisplayName = stringValue(object, "name", "displayName", "title")
			}
		}
		if typeValue == "message" {
			result.MessageCount++
			if parentID, _ := object["parentId"].(string); parentID != "" {
				childCounts[parentID]++
			}
			if message, ok := object["message"].(map[string]any); ok {
				if model := modelDescription(message); model != "" {
					result.LatestModel = model
				}
				if result.FirstUserMessage == "" {
					if role, _ := message["role"].(string); role == "user" {
						result.FirstUserMessage = contentPreview(message["content"])
					}
				}
			} else {
				if model := modelDescription(object); model != "" {
					result.LatestModel = model
				}
				if result.FirstUserMessage == "" {
					if role, _ := object["role"].(string); role == "user" {
						result.FirstUserMessage = contentPreview(object["content"])
					}
				}
			}
		}
		if typeValue == "label" {
			if targetID, _ := object["targetId"].(string); targetID != "" {
				labelTargets[targetID] = struct{}{}
			}
		}
		if typeValue == "branch_summary" {
			result.BranchSummaryCount++
		}
	}
	for _, count := range childCounts {
		if count > 1 {
			result.BranchCount++
		}
	}
	result.LabelCount = len(labelTargets)
	return result
}

func readAllLines(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	parts := bytes.Split(data, []byte("\n"))
	lines := make([]string, len(parts))
	for i, part := range parts {
		lines[i] = string(part)
	}
	return lines, nil
}

func readPreviewLines(path string, limit int) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	const chunkSize = 64 * 1024
	buffer := make([]byte, chunkSize)
	pending := make([]byte, 0, chunkSize)
	lines := make([]string, 0, limit)

	for len(lines) < limit {
		n, err := file.Read(buffer)
		if n > 0 {
			pending = append(pending, buffer[:n]...)
			for len(lines) < limit {
				index := bytes.IndexByte(pending, '\n')
				if index < 0 {
					break
				}
				lines = append(lines, string(pending[:index]))
				pending = pending[index+1:]
			}
		}
		if err != nil {
			if err == io.EOF {
				break
			}
			return lines, err
		}
	}
	if len(lines) < limit && len(pending) > 0 {
		lines = append(lines, string(pending))
	}
	return lines, nil
}

func readLastLines(path string, limit int) ([]string, int, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, 0, err
	}
	const chunkSize int64 = 64 * 1024
	var offset = info.Size()
	buffer := make([]byte, 0, chunkSize*2)
	newlineCount := 0

	for offset > 0 && newlineCount <= limit {
		readSize := chunkSize
		if offset < readSize {
			readSize = offset
		}
		offset -= readSize
		chunk := make([]byte, readSize)
		if _, err := file.ReadAt(chunk, offset); err != nil && err != io.EOF {
			return nil, 0, err
		}
		buffer = append(chunk, buffer...)
		newlineCount = bytes.Count(buffer, []byte("\n"))
	}

	totalLines, err := countLines(path)
	if err != nil {
		return nil, 0, err
	}

	parts := bytes.Split(buffer, []byte("\n"))
	if limit > 0 && len(parts) > limit {
		parts = parts[len(parts)-limit:]
	}
	lines := make([]string, len(parts))
	for i, part := range parts {
		lines[i] = string(part)
	}
	return lines, totalLines, nil
}

func countLines(path string) (int, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer file.Close()

	const chunkSize = 64 * 1024
	buffer := make([]byte, chunkSize)
	total := 0
	readAny := false
	lastEndedWithNewline := false
	for {
		n, err := file.Read(buffer)
		if n > 0 {
			readAny = true
			chunk := buffer[:n]
			total += bytes.Count(chunk, []byte("\n"))
			lastEndedWithNewline = chunk[len(chunk)-1] == '\n'
		}
		if err != nil {
			if err == io.EOF {
				break
			}
			return 0, err
		}
	}
	if !readAny {
		return 0, nil
	}
	if !lastEndedWithNewline {
		total++
	}
	return total, nil
}

func projectTitle(projectID string, sessions []sessionRecord) string {
	if len(sessions) > 0 && strings.TrimSpace(sessions[0].WorkingDirectory) != "" {
		base := filepath.Base(sessions[0].WorkingDirectory)
		if strings.TrimSpace(base) != "" && base != "." && base != string(filepath.Separator) {
			return base
		}
	}
	return strings.Trim(projectID, "-")
}

func encodedProjectID(workingDirectory string) string {
	clean := filepath.Clean(workingDirectory)
	parts := strings.FieldsFunc(clean, func(r rune) bool { return r == filepath.Separator })
	if len(parts) == 0 {
		return "--root--"
	}
	return "--" + strings.Join(parts, "-") + "--"
}

func stringValue(object map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := object[key].(string); ok && strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func modelDescription(object map[string]any) string {
	for _, key := range []string{"model", "modelId", "modelID"} {
		if value, ok := object[key].(string); ok && strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func contentPreview(value any) string {
	switch content := value.(type) {
	case string:
		return preview(content)
	case []any:
		for _, block := range content {
			if object, ok := block.(map[string]any); ok {
				if text, ok := object["text"].(string); ok && strings.TrimSpace(text) != "" {
					return preview(text)
				}
			}
		}
	}
	return ""
}

func preview(value string) string {
	trimmed := strings.TrimSpace(value)
	if len(trimmed) <= 80 {
		return trimmed
	}
	return trimmed[:80]
}

func optionalInt(raw string) (int, bool, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, false, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, false, err
	}
	return value, true, nil
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{"error": message})
}

func getenvDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func expandHome(path string) string {
	if !strings.HasPrefix(path, "~") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, strings.TrimPrefix(path, "~/"))
	}
	return path
}

func sanitizeUploadName(name string) string {
	base := filepath.Base(strings.TrimSpace(name))
	if base == "." || base == string(filepath.Separator) || base == "" {
		base = "attachment"
	}
	base = strings.ReplaceAll(base, string(filepath.Separator), "-")
	return base
}

func uniqueUploadName(name string) string {
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	if base == "" {
		base = "attachment"
	}
	return base + "-" + strconv.FormatInt(time.Now().UnixNano(), 10) + ext
}

func xmlEscape(value string) string {
	return strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		"\"", "&quot;",
	).Replace(value)
}

// --- Live catalog SSE stream ---

// catalogBroker fans out full catalog snapshots to all connected SSE clients.
// Sends are non-blocking: a slow client that cannot keep up simply misses
// intermediate snapshots and receives the most recent one.
type catalogBroker struct {
	mu          sync.RWMutex
	subscribers map[chan catalogResponse]struct{}
}

func newCatalogBroker() *catalogBroker {
	return &catalogBroker{subscribers: map[chan catalogResponse]struct{}{}}
}

func (b *catalogBroker) subscribe() chan catalogResponse {
	ch := make(chan catalogResponse, 4)
	b.mu.Lock()
	b.subscribers[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *catalogBroker) unsubscribe(ch chan catalogResponse) {
	b.mu.Lock()
	if _, ok := b.subscribers[ch]; ok {
		delete(b.subscribers, ch)
		close(ch)
	}
	b.mu.Unlock()
}

func (b *catalogBroker) broadcast(snapshot catalogResponse) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	for ch := range b.subscribers {
		select {
		case ch <- snapshot:
		default:
		}
	}
}

func (b *catalogBroker) subscriberCount() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.subscribers)
}

// refreshAndBroadcast forces a fresh catalog rebuild and pushes the result
// to every SSE subscriber. Safe to call concurrently.
func (s *server) refreshAndBroadcast() {
	if err := s.refreshCatalog(true); err != nil {
		log.Printf("catalog refresh failed: %v", err)
		return
	}
	s.mu.RLock()
	snapshot := s.snapshot
	s.mu.RUnlock()
	s.broker.broadcast(snapshot)
}

// watchCatalog runs in its own goroutine. It watches the agent sessions
// directory recursively via fsnotify and triggers a debounced refresh +
// broadcast on any change. New subdirectories are added to the watch list
// on the fly so newly created project folders are picked up.
func (s *server) watchCatalog() {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		log.Printf("fsnotify: live catalog updates disabled: %v", err)
		return
	}
	defer watcher.Close()

	sessionsRoot := filepath.Join(s.agentDir, "sessions")
	if err := s.addWatchRecursive(watcher, sessionsRoot); err != nil {
		log.Printf("fsnotify: live catalog watcher incomplete for %s: %v", sessionsRoot, err)
	}

	const debounce = 300 * time.Millisecond
	var debounceTimer *time.Timer

	schedule := func() {
		if debounceTimer != nil {
			debounceTimer.Stop()
		}
		debounceTimer = time.AfterFunc(debounce, s.refreshAndBroadcast)
	}

	for {
		select {
		case event, ok := <-watcher.Events:
			if !ok {
				return
			}
			if event.Op&fsnotify.Create != 0 {
				if info, statErr := os.Stat(event.Name); statErr == nil && info.IsDir() {
					if addErr := watcher.Add(event.Name); addErr != nil {
						log.Printf("fsnotify: watch %s: %v", event.Name, addErr)
					}
				}
			}
			schedule()
		case err, ok := <-watcher.Errors:
			if !ok {
				return
			}
			log.Printf("fsnotify error: %v", err)
		}
	}
}

func (s *server) addWatchRecursive(watcher *fsnotify.Watcher, root string) error {
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			return watcher.Add(path)
		}
		return nil
	})
}

// handleSessionsStream serves GET /sessions/stream as a Server-Sent Events
// endpoint. It sends a full catalog snapshot on connect, then keeps the
// connection open sending fresh snapshots whenever the catalog changes and a
// short heartbeat comment every 15s to keep proxies and browsers happy.
func (s *server) handleSessionsStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	// Subscribe before refreshing so any change that happens during the
	// initial refresh is delivered via the channel rather than being missed.
	ch := s.broker.subscribe()
	defer s.broker.unsubscribe(ch)

	if err := s.refreshCatalogIfNeeded(); err != nil {
		writeSSEError(w, flusher, err.Error())
		return
	}
	s.mu.RLock()
	initial := s.snapshot
	s.mu.RUnlock()
	if !writeSSE(w, flusher, "snapshot", initial) {
		return
	}

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			if _, err := io.WriteString(w, ": ping\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case snapshot, ok := <-ch:
			if !ok {
				return
			}
			if !writeSSE(w, flusher, "snapshot", snapshot) {
				return
			}
		}
	}
}

// writeSSE serialises payload as a single SSE event. Returns false if the
// underlying writer is broken (client disconnect), so the caller can abort.
func writeSSE(w http.ResponseWriter, flusher http.Flusher, event string, payload any) bool {
	data, err := json.Marshal(payload)
	if err != nil {
		return false
	}
	if _, err := io.WriteString(w, "event: "+event+"\ndata: "); err != nil {
		return false
	}
	if _, err := w.Write(data); err != nil {
		return false
	}
	if _, err := io.WriteString(w, "\n\n"); err != nil {
		return false
	}
	flusher.Flush()
	return true
}

func writeSSEError(w http.ResponseWriter, flusher http.Flusher, message string) {
	_, _ = io.WriteString(w, "event: error\ndata: ")
	data, _ := json.Marshal(map[string]string{"error": message})
	_, _ = w.Write(data)
	_, _ = io.WriteString(w, "\n\n")
	flusher.Flush()
}
