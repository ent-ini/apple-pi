package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestSplitJSONLLinesDropsOnlyTrailingEmptyLine(t *testing.T) {
	if lines := splitJSONLLines([]byte{}); len(lines) != 0 {
		t.Fatalf("empty input = %#v, want []", lines)
	}
	if lines := splitJSONLLines([]byte("a\nb\n")); !reflect.DeepEqual(lines, []string{"a", "b"}) {
		t.Fatalf("trailing newline = %#v", lines)
	}
	if lines := splitJSONLLines([]byte("a\n\n")); !reflect.DeepEqual(lines, []string{"a", ""}) {
		t.Fatalf("intentional blank line = %#v", lines)
	}
}

func TestReadEventRecordsAfterReturnsCatchUpRecords(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\",\"id\":\"b\"}\n{\"type\":\"message\",\"id\":\"c\"}\n")

	records, err := readEventRecordsAfter(path, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 2 {
		t.Fatalf("len(records) = %d, want 2", len(records))
	}
	if records[0].Line != 1 || records[0].Raw != "{\"type\":\"message\",\"id\":\"b\"}" || records[1].Line != 2 || records[1].Raw != "{\"type\":\"message\",\"id\":\"c\"}" {
		t.Fatalf("records = %#v", records)
	}
}

func TestReadEventRecordsAfterKeepsValidTrailingLineWithoutNewline(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\",\"id\":\"b\"}")

	records, err := readEventRecordsAfter(path, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Line != 1 || records[0].Raw != "{\"type\":\"message\",\"id\":\"b\"}" {
		t.Fatalf("records = %#v", records)
	}
}

func TestReadEventRecordsAfterSkipsPartialTrailingLine(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\"")

	records, err := readEventRecordsAfter(path, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 0 {
		t.Fatalf("records = %#v, want no partial trailing line", records)
	}
}

func TestReadAllLinesSkipsPartialTrailingLine(t *testing.T) {
	path := writeTempSessionFile(t, "{\"type\":\"session\"}\n{\"type\":\"message\"")

	lines, err := readAllLines(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(lines, []string{"{\"type\":\"session\"}"}) {
		t.Fatalf("lines = %#v", lines)
	}
}

func TestReadLastLinesTrimsTrailingEmptyLineAndPreservesLineNumbers(t *testing.T) {
	path := writeTempSessionFile(t, "a\nb\nc\n")

	lines, total, err := readLastLines(path, 2)
	if err != nil {
		t.Fatal(err)
	}
	if total != 3 {
		t.Fatalf("total = %d, want 3", total)
	}
	if !reflect.DeepEqual(lines, []string{"b", "c"}) {
		t.Fatalf("lines = %#v", lines)
	}

	all, err := readAllLines(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(all, []string{"a", "b", "c"}) {
		t.Fatalf("all lines = %#v", all)
	}
}

func TestBearerTokenMatches(t *testing.T) {
	if !bearerTokenMatches("Bearer secret-token", "secret-token") {
		t.Fatal("valid bearer token did not match")
	}
	for _, header := range []string{"", "secret-token", "Bearer wrong", "Basic secret-token"} {
		if bearerTokenMatches(header, "secret-token") {
			t.Fatalf("header %q unexpectedly matched", header)
		}
	}
}

func TestHandleFilesRejectsPathsOutsideBrowsableRoots(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	agentDir := filepath.Join(home, ".pi", "agent")
	outside := filepath.Join(base, "outside")
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)

	server := &server{agentDir: agentDir}
	request := httptest.NewRequest(http.MethodGet, "/files?path="+outside, nil)
	response := httptest.NewRecorder()

	server.handleFiles(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusForbidden, response.Body.String())
	}
}

func TestHandleFilesRejectsSymlinkEscape(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	agentDir := filepath.Join(home, ".pi", "agent")
	outside := filepath.Join(base, "outside")
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	symlinkPath := filepath.Join(home, "escape")
	if err := os.Symlink(outside, symlinkPath); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	t.Setenv("HOME", home)

	server := &server{agentDir: agentDir}
	request := httptest.NewRequest(http.MethodGet, "/files?path="+symlinkPath, nil)
	response := httptest.NewRecorder()

	server.handleFiles(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusForbidden, response.Body.String())
	}
}

func TestHandleFilesOmitsParentOutsideBrowsableRoots(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	agentDir := filepath.Join(home, ".pi", "agent")
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)

	server := &server{agentDir: agentDir}
	request := httptest.NewRequest(http.MethodGet, "/files?path="+home, nil)
	response := httptest.NewRecorder()

	server.handleFiles(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusOK, response.Body.String())
	}
	var payload fileListResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.Parent != "" {
		t.Fatalf("parent = %q, want empty", payload.Parent)
	}
}

func TestHandleUploadsUsesPrivatePermissions(t *testing.T) {
	agentDir := t.TempDir()
	server := &server{agentDir: agentDir}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "notes.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte("secret")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPost, "/uploads", &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response := httptest.NewRecorder()

	server.handleUploads(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusOK, response.Body.String())
	}
	uploadDir := filepath.Join(agentDir, "uploads")
	if info, err := os.Stat(uploadDir); err != nil || info.Mode().Perm() != 0o700 {
		if err != nil {
			t.Fatal(err)
		}
		t.Fatalf("upload dir mode = %o, want 700", info.Mode().Perm())
	}
	var payload uploadResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(payload.Path, uploadDir+string(os.PathSeparator)) {
		t.Fatalf("upload path %q outside %q", payload.Path, uploadDir)
	}
	if info, err := os.Stat(payload.Path); err != nil || info.Mode().Perm() != 0o600 {
		if err != nil {
			t.Fatal(err)
		}
		t.Fatalf("upload file mode = %o, want 600", info.Mode().Perm())
	}
}

func TestResolveAttachmentPathsRejectsSymlinkEscape(t *testing.T) {
	agentDir := t.TempDir()
	uploadDir := filepath.Join(agentDir, "uploads")
	outside := filepath.Join(agentDir, "outside")
	if err := os.MkdirAll(uploadDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	secretPath := filepath.Join(outside, "secret.txt")
	if err := os.WriteFile(secretPath, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	linkPath := filepath.Join(uploadDir, "link.txt")
	if err := os.Symlink(secretPath, linkPath); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}

	_, err := (&server{agentDir: agentDir}).resolveAttachmentPaths([]attachmentReference{{Path: linkPath}})
	if err == nil || !strings.Contains(err.Error(), "outside uploads") {
		t.Fatalf("err = %v, want outside uploads error", err)
	}
}

func TestLoadDefaultRuntimeFastIncludesEmptyContextUsage(t *testing.T) {
	agentDir := t.TempDir()
	settings := `{"defaultProvider":"opencode-go","defaultModel":"minimax-m3","defaultThinkingLevel":"off"}`
	if err := os.WriteFile(filepath.Join(agentDir, "settings.json"), []byte(settings), 0o600); err != nil {
		t.Fatal(err)
	}

	payload := (&server{agentDir: agentDir}).loadDefaultRuntimeFast(t.TempDir())
	if payload.Runtime.ContextUsage == nil {
		t.Fatal("ContextUsage is nil")
	}
	if payload.Runtime.ContextUsage.Tokens == nil || *payload.Runtime.ContextUsage.Tokens != 0 {
		t.Fatalf("ContextUsage.Tokens = %#v, want 0", payload.Runtime.ContextUsage.Tokens)
	}
	if payload.Runtime.ContextUsage.ContextWindow != 512000 {
		t.Fatalf("ContextWindow = %d, want 512000", payload.Runtime.ContextUsage.ContextWindow)
	}
	if payload.Runtime.ContextUsage.Percent == nil || *payload.Runtime.ContextUsage.Percent != 0 {
		t.Fatalf("Percent = %#v, want 0", payload.Runtime.ContextUsage.Percent)
	}
}

func writeTempSessionFile(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "session.jsonl")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
