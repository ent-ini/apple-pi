package main

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type server struct {
	agentDir string
	token    string

	mu          sync.RWMutex
	lastRefresh time.Time
	snapshot    catalogResponse
	sessionsByID map[string]sessionRecord
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

func main() {
	agentDir := getenvDefault("PI_APPD_AGENT_DIR", "~/.pi/agent")
	addr := getenvDefault("PI_APPD_ADDR", "127.0.0.1:8787")
	token := strings.TrimSpace(os.Getenv("PI_APPD_TOKEN"))

	srv := &server{
		agentDir:   expandHome(agentDir),
		token:      token,
		sessionsByID: map[string]sessionRecord{},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealthz)
	mux.HandleFunc("/sessions", srv.handleSessions)
	mux.HandleFunc("/sessions/", srv.handleSessionSubroutes)
	mux.HandleFunc("/files", srv.handleFiles)

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
	if err := s.refreshCatalogIfNeeded(); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	writeJSON(w, http.StatusOK, s.snapshot)
}

func (s *server) handleSessionSubroutes(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/sessions/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || strings.TrimSpace(parts[0]) == "" {
		writeError(w, http.StatusNotFound, "not found")
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
		writeJSON(w, http.StatusOK, record)
		return
	}
	if len(parts) == 2 && parts[1] == "events" {
		s.handleSessionEvents(w, r, record)
		return
	}
	writeError(w, http.StatusNotFound, "not found")
}

func (s *server) handleSessionEvents(w http.ResponseWriter, r *http.Request, record sessionRecord) {
	lines, err := readAllLines(record.FilePath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

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
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 0 {
			writeError(w, http.StatusBadRequest, "invalid limit")
			return
		}
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

func (s *server) refreshCatalogIfNeeded() error {
	s.mu.RLock()
	fresh := time.Since(s.lastRefresh) < 2*time.Second && len(s.snapshot.Sessions) > 0
	s.mu.RUnlock()
	if fresh {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.lastRefresh) < 2*time.Second && len(s.snapshot.Sessions) > 0 {
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
	lines, err := readAllLines(path)
	if err != nil {
		return parsedSession{}, err
	}
	limit := len(lines)
	if limit > 240 {
		limit = 240
	}
	return parseSessionLines(lines[:limit]), nil
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
			if parentID, _ := object["parentId"].(string); parentID != "" {
				childCounts[parentID]++
			}
			if message, ok := object["message"].(map[string]any); ok {
				result.MessageCount++
				if model := modelDescription(message); model != "" {
					result.LatestModel = model
				}
				if result.FirstUserMessage == "" {
					if role, _ := message["role"].(string); role == "user" {
						result.FirstUserMessage = contentPreview(message["content"])
					}
				}
			}
		} else if object["message"] != nil || object["content"] != nil || object["role"] != nil {
			result.MessageCount++
			if model := modelDescription(object); model != "" {
				result.LatestModel = model
			}
			if result.FirstUserMessage == "" {
				if role, _ := object["role"].(string); role == "user" {
					result.FirstUserMessage = contentPreview(object["content"])
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

