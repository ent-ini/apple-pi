package main

import (
	"os"
	"path/filepath"
	"reflect"
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
