package agent

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestPiAgent_BuildArgs(t *testing.T) {
	pa := &piAgent{bin: "pi"}
	args := pa.buildArgs(false, "")

	expected := []string{"--mode", "json", "--no-session"}

	if len(args) != len(expected) {
		t.Fatalf("expected %d args, got %d: %v", len(expected), len(args), args)
	}
	for i, want := range expected {
		if args[i] != want {
			t.Errorf("arg[%d]: expected %q, got %q", i, want, args[i])
		}
	}
}

func TestPiAgent_BuildArgs_PrependsExtraArgs(t *testing.T) {
	pa := &piAgent{bin: "pi", extraArgs: []string{"--provider", "google"}}
	args := pa.buildArgs(false, "")

	expected := []string{"--provider", "google", "--mode", "json", "--no-session"}

	if len(args) != len(expected) {
		t.Fatalf("expected %d args, got %d: %v", len(expected), len(args), args)
	}
	for i, want := range expected {
		if args[i] != want {
			t.Errorf("arg[%d]: expected %q, got %q", i, want, args[i])
		}
	}
}

func TestPiAgent_BuildArgs_OptOutAddsNoContextFiles(t *testing.T) {
	pa := &piAgent{bin: "pi", extraArgs: []string{"--system-prompt"}, disableProjectSettings: true}
	args := pa.buildArgs(false, "")
	expected := []string{"--no-context-files", "--system-prompt", "--mode", "json", "--no-session"}
	if len(args) != len(expected) {
		t.Fatalf("expected %d args, got %d: %v", len(expected), len(args), args)
	}
	for i, want := range expected {
		if args[i] != want {
			t.Errorf("arg[%d]: expected %q, got %q", i, want, args[i])
		}
	}
}

func TestPiAgent_BuildArgs_OptOutDoesNotDuplicateNoContextFiles(t *testing.T) {
	pa := &piAgent{bin: "pi", extraArgs: []string{"--provider", "google", "-nc"}, disableProjectSettings: true}
	args := pa.buildArgs(false, "")
	expected := []string{"-nc", "--provider", "google", "--mode", "json", "--no-session"}
	if len(args) != len(expected) {
		t.Fatalf("expected %d args, got %d: %v", len(expected), len(args), args)
	}
	for i, want := range expected {
		if args[i] != want {
			t.Errorf("arg[%d]: expected %q, got %q", i, want, args[i])
		}
	}
}

func TestPiAgent_BuildArgs_OptOutPreservesNoContextFilesOptionValue(t *testing.T) {
	pa := &piAgent{bin: "pi", extraArgs: []string{"--system-prompt", "-nc"}, disableProjectSettings: true}
	args := pa.buildArgs(false, "")
	expected := []string{"--no-context-files", "--system-prompt", "-nc", "--mode", "json", "--no-session"}
	if len(args) != len(expected) {
		t.Fatalf("expected %d args, got %d: %v", len(expected), len(args), args)
	}
	for i, want := range expected {
		if args[i] != want {
			t.Errorf("arg[%d]: expected %q, got %q", i, want, args[i])
		}
	}
}

func TestPiAgent_BuildArgs_SessionResume(t *testing.T) {
	pa := &piAgent{bin: "pi"}
	args := pa.buildArgs(true, "019f4d4d-5dc0-75c1-8efe-adf4531bd733")

	expected := []string{"--mode", "json", "--session-id", "019f4d4d-5dc0-75c1-8efe-adf4531bd733"}
	if len(args) != len(expected) {
		t.Fatalf("expected %d args, got %d: %v", len(expected), len(args), args)
	}
	for i, want := range expected {
		if args[i] != want {
			t.Errorf("arg[%d]: expected %q, got %q", i, want, args[i])
		}
	}
	for _, a := range args {
		if a == "--no-session" {
			t.Fatalf("resume must not pass --no-session: %v", args)
		}
	}
}

func TestPiAgent_BuildArgs_SessionFresh(t *testing.T) {
	pa := &piAgent{bin: "pi"}
	args := pa.buildArgs(true, "")

	expected := []string{"--mode", "json"}
	if len(args) != len(expected) {
		t.Fatalf("expected %d args, got %d: %v", len(expected), len(args), args)
	}
	for i, want := range expected {
		if args[i] != want {
			t.Errorf("arg[%d]: expected %q, got %q", i, want, args[i])
		}
	}
	// A fresh resumable session drops --no-session so pi mints and persists a
	// project session id for later rounds.
}

func TestPiParser_CapturesSessionEventID(t *testing.T) {
	pp := &piParser{}
	events := `{"type":"session","version":3,"id":"019ffd65-8e8a-7b63-bff9-bc592a6d98f3","cwd":"/tmp"}
{"type":"agent_end","messages":[{"role":"assistant","content":"ok"}]}
`
	if err := pp.parse(context.Background(), strings.NewReader(events)); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if pp.sessionID != "019ffd65-8e8a-7b63-bff9-bc592a6d98f3" {
		t.Fatalf("sessionID = %q, want the session event id", pp.sessionID)
	}
}

func TestPiAgent_NeutralizesGateInstructions(t *testing.T) {
	if NeutralizesGateInstructions(&piAgent{bin: "pi"}) {
		t.Error("pi must not report neutralized without the opt-out")
	}
	if !NeutralizesGateInstructions(&piAgent{bin: "pi", disableProjectSettings: true}) {
		t.Error("pi must report neutralized under the opt-out")
	}
}

func TestPiAgent_BuildPromptIncludesSchema(t *testing.T) {
	schema := json.RawMessage(`{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}`)
	prompt := buildPiPrompt("do a thing", schema)
	if !strings.Contains(prompt, "do a thing") {
		t.Errorf("prompt missing user prompt: %s", prompt)
	}
	if !strings.Contains(prompt, "drill final output contract") {
		t.Errorf("prompt missing contract header: %s", prompt)
	}
	if !strings.Contains(prompt, "summary") {
		t.Errorf("prompt missing schema property: %s", prompt)
	}
}

func TestPiAgent_BuildPromptOmitsContractWhenSchemaEmpty(t *testing.T) {
	prompt := buildPiPrompt("do a thing", nil)
	if prompt != "do a thing" {
		t.Errorf("expected raw prompt when no schema, got: %q", prompt)
	}
}

func writeFakePi(t *testing.T, dir, posixScript, windowsScript string) string {
	t.Helper()

	name := "pi"
	script := posixScript
	if runtime.GOOS == "windows" {
		name = "pi.cmd"
		script = windowsScript
	}

	bin := filepath.Join(dir, name)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake pi: %v", err)
	}
	return bin
}

func TestPiAgent_RunOptOutPassesNoContextFilesToCLI(t *testing.T) {
	workDir := t.TempDir()
	bin := writeFakePi(t, t.TempDir(), `#!/bin/sh
printf '%s\n' "$*" > pi-argv.txt
cat > /dev/null
printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":"ok"}]}'
`, strings.Join([]string{
		"@echo off",
		"echo %* > pi-argv.txt",
		"more > nul",
		"echo {\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":\"ok\"}]}",
	}, "\r\n"))

	pa := &piAgent{
		bin:                    bin,
		extraArgs:              []string{"--provider", "google"},
		disableProjectSettings: true,
	}
	if _, err := pa.Run(context.Background(), RunOpts{Prompt: "review", CWD: workDir}); err != nil {
		t.Fatalf("run pi: %v", err)
	}

	argv, err := os.ReadFile(filepath.Join(workDir, "pi-argv.txt"))
	if err != nil {
		t.Fatalf("read captured pi argv: %v", err)
	}
	got := strings.TrimSpace(string(argv))
	want := "--no-context-files --provider google --mode json --no-session"
	if got != want {
		t.Fatalf("pi argv = %q, want %q", got, want)
	}
	t.Logf("pi received argv: %s", got)
}

func TestPiAgent_RunSessionReuseReportsIdentity(t *testing.T) {
	workDir := t.TempDir()
	bin := writeFakePi(t, t.TempDir(), `#!/bin/sh
printf '%s\n' "$*" > pi-argv.txt
cat > /dev/null
printf '%s\n' '{"type":"session","id":"sess-pi-7"}'
printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":"ok"}]}'
`, strings.Join([]string{
		"@echo off",
		"echo %* > pi-argv.txt",
		"more > nul",
		"echo {\"type\":\"session\",\"id\":\"sess-pi-7\"}",
		"echo {\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":\"ok\"}]}",
	}, "\r\n"))

	pa := &piAgent{bin: bin}
	result, err := pa.Run(context.Background(), RunOpts{Prompt: "fix", CWD: workDir, Session: &SessionRef{}})
	if err != nil {
		t.Fatalf("run pi: %v", err)
	}
	if result.SessionID != "sess-pi-7" {
		t.Fatalf("SessionID = %q, want the session event id", result.SessionID)
	}
	if result.Resumed {
		t.Fatal("fresh session must not report Resumed")
	}

	argv, err := os.ReadFile(filepath.Join(workDir, "pi-argv.txt"))
	if err != nil {
		t.Fatalf("read captured pi argv: %v", err)
	}
	got := strings.TrimSpace(string(argv))
	if strings.Contains(got, "--no-session") {
		t.Fatalf("reuse argv must not contain --no-session: %q", got)
	}
}

func TestPiAgent_RunSessionResumePassesID(t *testing.T) {
	workDir := t.TempDir()
	bin := writeFakePi(t, t.TempDir(), `#!/bin/sh
printf '%s\n' "$*" > pi-argv.txt
cat > /dev/null
printf '%s\n' '{"type":"session","id":"sess-pi-9"}'
printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":"ok"}]}'
`, strings.Join([]string{
		"@echo off",
		"echo %* > pi-argv.txt",
		"more > nul",
		"echo {\"type\":\"session\",\"id\":\"sess-pi-9\"}",
		"echo {\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":\"ok\"}]}",
	}, "\r\n"))

	pa := &piAgent{bin: bin}
	result, err := pa.Run(context.Background(), RunOpts{
		Prompt:  "fix",
		CWD:     workDir,
		Session: &SessionRef{ID: "sess-pi-9"},
	})
	if err != nil {
		t.Fatalf("run pi: %v", err)
	}
	if result.SessionID != "sess-pi-9" {
		t.Fatalf("SessionID = %q, want the resumed id", result.SessionID)
	}
	if !result.Resumed {
		t.Fatal("resume invocation must report Resumed")
	}

	argv, err := os.ReadFile(filepath.Join(workDir, "pi-argv.txt"))
	if err != nil {
		t.Fatalf("read captured pi argv: %v", err)
	}
	got := strings.TrimSpace(string(argv))
	want := "--mode json --session-id sess-pi-9"
	if got != want {
		t.Fatalf("pi argv = %q, want %q", got, want)
	}
}

func TestPiAgent_RunColdDoesNotReportSession(t *testing.T) {
	workDir := t.TempDir()
	bin := writeFakePi(t, t.TempDir(), `#!/bin/sh
cat > /dev/null
printf '%s\n' '{"type":"session","id":"sess-ephemeral"}'
printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":"ok"}]}'
`, strings.Join([]string{
		"@echo off",
		"more > nul",
		"echo {\"type\":\"session\",\"id\":\"sess-ephemeral\"}",
		"echo {\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":\"ok\"}]}",
	}, "\r\n"))

	pa := &piAgent{bin: bin}
	result, err := pa.Run(context.Background(), RunOpts{Prompt: "review", CWD: workDir})
	if err != nil {
		t.Fatalf("run pi: %v", err)
	}
	if result.SessionID != "" {
		t.Fatalf("cold run must not report a session identity, got %q", result.SessionID)
	}
}

func TestPiAgent_RunParsesAssistantContentAndUsage(t *testing.T) {
	dir := t.TempDir()
	// Fake pi that emits a streaming text_delta plus a final message_end with
	// content blocks and a usage record. Mirrors the live JSONL shape.
	bin := writeFakePi(t, dir, `#!/bin/sh
cat > /dev/null
printf '%s\n' '{"type":"message_update","message":{"role":"assistant","responseId":"r1"},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"{\"ok"}}'
printf '%s\n' '{"type":"message_update","message":{"role":"assistant","responseId":"r1"},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"\":true}"}}'
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","responseId":"r1","content":[{"type":"text","text":"{\"ok\":true}"}],"usage":{"input":11,"output":7,"cacheRead":3,"cacheWrite":1}}}'
printf '%s\n' '{"type":"agent_end","messages":[]}'
`, strings.Join([]string{
		"@echo off",
		"more > nul",
		"echo {\"type\":\"message_update\",\"message\":{\"role\":\"assistant\",\"responseId\":\"r1\"},\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"{\\\"ok\"}}",
		"echo {\"type\":\"message_update\",\"message\":{\"role\":\"assistant\",\"responseId\":\"r1\"},\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"\\\":true}\"}}",
		"echo {\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"responseId\":\"r1\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true}\"}],\"usage\":{\"input\":11,\"output\":7,\"cacheRead\":3,\"cacheWrite\":1}}}",
		"echo {\"type\":\"agent_end\",\"messages\":[]}",
	}, "\r\n"))

	schema := json.RawMessage(`{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}`)
	pa := &piAgent{bin: bin}

	var chunks []string
	result, err := pa.Run(context.Background(), RunOpts{
		Prompt:     "review",
		CWD:        t.TempDir(),
		JSONSchema: schema,
		OnChunk:    func(s string) { chunks = append(chunks, s) },
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if string(result.Output) != `{"ok":true}` {
		t.Fatalf("unexpected output: %s", string(result.Output))
	}
	if result.Usage.InputTokens != 11 || result.Usage.OutputTokens != 7 ||
		result.Usage.CacheReadTokens != 3 || result.Usage.CacheCreationTokens != 1 {
		t.Fatalf("unexpected usage: %+v", result.Usage)
	}
	if len(chunks) == 0 {
		t.Fatal("expected onChunk to receive streaming text")
	}
	// OnChunk must receive the incremental deltas, not cumulative state.
	// Otherwise the TUI log buffer (which appends each chunk) duplicates
	// the running prefix.
	wantChunks := []string{`{"ok`, `":true}`}
	if len(chunks) != len(wantChunks) {
		t.Fatalf("expected %d delta chunks, got %d: %v", len(wantChunks), len(chunks), chunks)
	}
	for i, want := range wantChunks {
		if chunks[i] != want {
			t.Errorf("chunk[%d] = %q, want %q", i, chunks[i], want)
		}
	}
}

func TestPiAgent_RunFallsBackToAgentEndMessages(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakePi(t, dir, `#!/bin/sh
cat > /dev/null
printf '%s\n' '{"type":"agent_end","messages":[{"role":"user","content":"prompt"},{"role":"assistant","content":"{\"ok\":true}"}]}'
`, strings.Join([]string{
		"@echo off",
		"more > nul",
		"echo {\"type\":\"agent_end\",\"messages\":[{\"role\":\"user\",\"content\":\"prompt\"},{\"role\":\"assistant\",\"content\":\"{\\\"ok\\\":true}\"}]}",
	}, "\r\n"))

	schema := json.RawMessage(`{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}`)
	pa := &piAgent{bin: bin}
	result, err := pa.Run(context.Background(), RunOpts{
		Prompt:     "review",
		CWD:        t.TempDir(),
		JSONSchema: schema,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if string(result.Output) != `{"ok":true}` {
		t.Fatalf("unexpected output: %s", string(result.Output))
	}
}

func TestPiParser_ClearsPriorAssistantErrorAfterSuccessfulRetry(t *testing.T) {
	stream := strings.Join([]string{
		`{"type":"message_end","message":{"role":"assistant","responseId":"r1","stopReason":"error","errorMessage":"transient failure"}}`,
		`{"type":"message_end","message":{"role":"assistant","responseId":"r2","stopReason":"stop","content":[{"type":"text","text":"success"}]}}`,
		`{"type":"agent_end","messages":[{"role":"assistant","responseId":"r1","stopReason":"error","errorMessage":"transient failure"},{"role":"assistant","responseId":"r2","stopReason":"stop","content":[{"type":"text","text":"success"}]}]}`,
	}, "\n")

	pp := &piParser{}
	if err := pp.parse(context.Background(), strings.NewReader(stream)); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if pp.assistantError != "" {
		t.Fatalf("expected successful retry to clear assistant error, got %q", pp.assistantError)
	}
	if got := pp.finalText(); got != "success" {
		t.Fatalf("expected final retry text, got %q", got)
	}
}

func TestPiParser_SumsUniqueAssistantUsageAcrossTurns(t *testing.T) {
	stream := strings.Join([]string{
		`{"type":"message_end","message":{"role":"assistant","responseId":"r1","stopReason":"toolUse","content":[{"type":"toolCall","name":"bash"}],"usage":{"input":10,"output":2,"cacheRead":3,"cacheWrite":4}}}`,
		`{"type":"turn_end","message":{"role":"assistant","responseId":"r1","stopReason":"toolUse","content":[{"type":"toolCall","name":"bash"}],"usage":{"input":10,"output":2,"cacheRead":3,"cacheWrite":4}}}`,
		`{"type":"message_end","message":{"role":"assistant","responseId":"r2","stopReason":"stop","content":[{"type":"text","text":"done"}],"usage":{"input":1,"output":5,"cacheRead":6,"cacheWrite":7}}}`,
		`{"type":"turn_end","message":{"role":"assistant","responseId":"r2","stopReason":"stop","content":[{"type":"text","text":"done"}],"usage":{"input":1,"output":5,"cacheRead":6,"cacheWrite":7}}}`,
		`{"type":"agent_end","messages":[{"role":"assistant","responseId":"r1","stopReason":"toolUse","content":[{"type":"toolCall","name":"bash"}],"usage":{"input":10,"output":2,"cacheRead":3,"cacheWrite":4}},{"role":"toolResult","content":[{"type":"text","text":"ok"}]},{"role":"assistant","responseId":"r2","stopReason":"stop","content":[{"type":"text","text":"done"}],"usage":{"input":1,"output":5,"cacheRead":6,"cacheWrite":7}}]}`,
	}, "\n")

	pp := &piParser{}
	if err := pp.parse(context.Background(), strings.NewReader(stream)); err != nil {
		t.Fatalf("parse: %v", err)
	}
	want := TokenUsage{InputTokens: 11, OutputTokens: 7, CacheReadTokens: 9, CacheCreationTokens: 11, Reported: true, CacheCreationReported: true}
	if pp.usage != want {
		t.Fatalf("usage = %+v, want %+v", pp.usage, want)
	}
}

func TestPiAgent_RunRejectsAssistantError(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakePi(t, dir, `#!/bin/sh
cat > /dev/null
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"auth failed","content":[{"type":"text","text":"{\"ok\":true}"}]}}'
`, strings.Join([]string{
		"@echo off",
		"more > nul",
		"echo {\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"error\",\"errorMessage\":\"auth failed\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true}\"}]}}",
	}, "\r\n"))

	pa := &piAgent{bin: bin}
	_, err := pa.Run(context.Background(), RunOpts{
		Prompt:     "review",
		CWD:        t.TempDir(),
		JSONSchema: json.RawMessage(`{"type":"object"}`),
	})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "auth failed") {
		t.Errorf("expected error to mention 'auth failed', got: %v", err)
	}
}

func TestPiAgent_RunRejectsEmptyOutput(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakePi(t, dir, `#!/bin/sh
cat > /dev/null
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"   "}]}}'
`, strings.Join([]string{
		"@echo off",
		"more > nul",
		"echo {\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"   \"}]}}",
	}, "\r\n"))

	pa := &piAgent{bin: bin}
	_, err := pa.Run(context.Background(), RunOpts{
		Prompt: "review",
		CWD:    t.TempDir(),
	})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "no text output") {
		t.Errorf("expected 'no text output', got: %v", err)
	}
}

func TestPiAgent_RunSurfacesNonZeroExit(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakePi(t, dir, `#!/bin/sh
cat > /dev/null
echo "boom" >&2
exit 2
`, strings.Join([]string{
		"@echo off",
		"more > nul",
		"echo boom 1>&2",
		"exit /b 2",
	}, "\r\n"))

	pa := &piAgent{bin: bin}
	_, err := pa.Run(context.Background(), RunOpts{
		Prompt: "review",
		CWD:    t.TempDir(),
	})
	if err == nil {
		t.Fatal("expected non-zero exit error")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("expected stderr in error message, got: %v", err)
	}
}

func TestPiAgent_RunCancelledByContext(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakePi(t, dir, `#!/bin/sh
cat > /dev/null
sleep 30
`, strings.Join([]string{
		"@echo off",
		"more > nul",
		"timeout /t 30 /nobreak > nul",
	}, "\r\n"))

	pa := &piAgent{bin: bin}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := pa.Run(ctx, RunOpts{
		Prompt: "review",
		CWD:    t.TempDir(),
	})
	if err == nil {
		t.Fatal("expected error from cancelled context")
	}
	if !errors.Is(err, context.Canceled) && !strings.Contains(err.Error(), "context canceled") {
		t.Logf("got error: %v", err)
	}
}
