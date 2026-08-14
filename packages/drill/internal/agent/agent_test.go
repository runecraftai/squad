package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/types"
)

func TestNew_KnownAgents(t *testing.T) {
	tests := []struct {
		name     string
		agent    types.AgentName
		bin      string
		wantName string
	}{
		{name: "claude", agent: types.AgentClaude, bin: "claude", wantName: "claude"},
		{name: "codex", agent: types.AgentCodex, bin: "codex", wantName: "codex"},
		{name: "rovodev", agent: types.AgentRovoDev, bin: "acli", wantName: "rovodev"},
		{name: "opencode", agent: types.AgentOpenCode, bin: "opencode", wantName: "opencode"},
		{name: "pi", agent: types.AgentPi, bin: "pi", wantName: "pi"},
		{name: "copilot", agent: types.AgentCopilot, bin: "copilot", wantName: "copilot"},
		{name: "cursor alias", agent: types.AgentCursor, bin: "acpx", wantName: "acp:cursor"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a, err := New(tt.agent, tt.bin, nil)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if a.Name() != tt.wantName {
				t.Errorf("expected name %q, got %q", tt.wantName, a.Name())
			}
		})
	}
}

func TestNew_ACPAgent(t *testing.T) {
	a, err := New("acp:gemini", "acpx", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if a.Name() != "acp:gemini" {
		t.Errorf("name = %q, want acp:gemini", a.Name())
	}
}

func TestNewWithOptions_ACPRegistryOverride(t *testing.T) {
	a, err := NewWithOptions("acp:local-gemini", "acpx", nil, Options{
		ACPRegistryOverrides: map[string]string{"local-gemini": "node /tmp/mock-acp.mjs"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	acpx, ok := a.(*acpxAgent)
	if !ok {
		t.Fatalf("agent type = %T, want *acpxAgent", a)
	}
	args := acpx.buildArgs(RunOpts{Prompt: "do work", CWD: "/repo"})
	joined := strings.Join(args, "\x00")
	if !strings.Contains(joined, "--agent\x00node /tmp/mock-acp.mjs") {
		t.Fatalf("args = %q, want raw --agent override", args)
	}
	if strings.Contains(joined, "\x00local-gemini\x00") {
		t.Fatalf("args = %q, should not include target subcommand when override is used", args)
	}
}

func TestACPAliasUsesDefaultCommand(t *testing.T) {
	a, err := New(types.AgentCursor, "acpx", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	acpx, ok := a.(*acpxAgent)
	if !ok {
		t.Fatalf("agent type = %T, want *acpxAgent", a)
	}
	if acpx.target != "cursor" {
		t.Errorf("target = %q, want cursor", acpx.target)
	}
	if acpx.rawCommand != "cursor-agent acp" {
		t.Errorf("rawCommand = %q, want cursor-agent acp", acpx.rawCommand)
	}
	args := acpx.buildArgs(RunOpts{Prompt: "do work"})
	joined := strings.Join(args, "\x00")
	if !strings.Contains(joined, "--agent\x00cursor-agent acp") {
		t.Fatalf("args = %q, want alias default command", args)
	}
}

func TestACPTargetUsesAliasDefaultCommand(t *testing.T) {
	a, err := New("acp:cursor", "acpx", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	acpx, ok := a.(*acpxAgent)
	if !ok {
		t.Fatalf("agent type = %T, want *acpxAgent", a)
	}
	if acpx.target != "cursor" {
		t.Errorf("target = %q, want cursor", acpx.target)
	}
	if acpx.rawCommand != "cursor-agent acp" {
		t.Errorf("rawCommand = %q, want cursor-agent acp", acpx.rawCommand)
	}
	args := acpx.buildArgs(RunOpts{Prompt: "do work"})
	joined := strings.Join(args, "\x00")
	if !strings.Contains(joined, "--agent\x00cursor-agent acp") {
		t.Fatalf("args = %q, want target default command", args)
	}
}

func TestACPAliasRegistryOverrideRespected(t *testing.T) {
	a, err := NewWithOptions(types.AgentCursor, "acpx", nil, Options{
		ACPRegistryOverrides: map[string]string{"cursor": "/opt/cursor/cursor-agent acp --profile work"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	acpx, ok := a.(*acpxAgent)
	if !ok {
		t.Fatalf("agent type = %T, want *acpxAgent", a)
	}
	if acpx.rawCommand != "/opt/cursor/cursor-agent acp --profile work" {
		t.Errorf("rawCommand = %q, want override value", acpx.rawCommand)
	}
}

func TestACPAliasBlankRegistryOverrideUsesDefaultCommand(t *testing.T) {
	a, err := NewWithOptions(types.AgentCursor, "acpx", nil, Options{
		ACPRegistryOverrides: map[string]string{"cursor": " \t"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	acpx, ok := a.(*acpxAgent)
	if !ok {
		t.Fatalf("agent type = %T, want *acpxAgent", a)
	}
	if acpx.rawCommand != "cursor-agent acp" {
		t.Errorf("rawCommand = %q, want cursor-agent acp", acpx.rawCommand)
	}
}

func TestACPAgentBuildArgsUsesExecMode(t *testing.T) {
	a := &acpxAgent{target: "gemini"}
	args := a.buildArgs(RunOpts{Prompt: "do work"})

	if got, want := args[len(args)-3:], []string{"gemini", "exec", "do work"}; strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("trailing args = %q, want %q", got, want)
	}
}

func TestACPAgentRunReportsJSONRPCErrorMessage(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell fixture is Unix-only")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "acpx")
	contents := `#!/bin/sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"not authenticated"}}'
exit 1
`
	if err := os.WriteFile(script, []byte(contents), 0o755); err != nil {
		t.Fatalf("write script: %v", err)
	}

	a, err := New("acp:gemini", script, nil)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	_, err = a.Run(context.Background(), RunOpts{Prompt: "do work", CWD: dir})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "not authenticated") {
		t.Fatalf("error = %v, want JSON-RPC error message", err)
	}
}

func TestParseAcpxJSONEventsParsesUsageFields(t *testing.T) {
	events := strings.Join([]string{
		`{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"usage_update","input_tokens":100,"output_tokens":50,"cache_read_input_tokens":30,"cache_creation_input_tokens":10}}}`,
		`{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"usage_update","_meta":{"usage":{"inputTokens":120,"outputTokens":60,"cacheReadInputTokens":40,"cacheCreationInputTokens":15}}}}}`,
		`{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}`,
	}, "\n") + "\n"
	var usage TokenUsage

	text, stdoutErr, err := parseAcpxJSONEvents(context.Background(), strings.NewReader(events), nil, &usage)
	if err != nil {
		t.Fatalf("parseAcpxJSONEvents() error = %v", err)
	}
	if stdoutErr != "" {
		t.Fatalf("stdout error = %q, want empty", stdoutErr)
	}
	if text != "done" {
		t.Fatalf("text = %q, want done", text)
	}
	want := TokenUsage{InputTokens: 120, OutputTokens: 60, CacheReadTokens: 40, CacheCreationTokens: 15, Reported: true, CacheCreationReported: true}
	if usage != want {
		t.Fatalf("usage = %+v, want %+v", usage, want)
	}
}

func TestParseAcpxJSONEventsParsesCacheWriteUsageFields(t *testing.T) {
	events := `{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"usage_update","input_tokens":5,"output_tokens":3,"cache_write_tokens":7}}}` + "\n"
	var usage TokenUsage

	_, _, err := parseAcpxJSONEvents(context.Background(), strings.NewReader(events), nil, &usage)
	if err != nil {
		t.Fatalf("parseAcpxJSONEvents() error = %v", err)
	}
	if usage.CacheCreationTokens != 7 {
		t.Fatalf("cache creation tokens = %d, want 7", usage.CacheCreationTokens)
	}
}

func TestParseAcpxJSONEventsParsesNormalizedCachedUsageFields(t *testing.T) {
	events := `{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"usage_update","inputTokens":5,"outputTokens":3,"cachedReadTokens":11,"cachedWriteTokens":13}}}` + "\n"
	var usage TokenUsage

	_, _, err := parseAcpxJSONEvents(context.Background(), strings.NewReader(events), nil, &usage)
	if err != nil {
		t.Fatalf("parseAcpxJSONEvents() error = %v", err)
	}
	want := TokenUsage{InputTokens: 5, OutputTokens: 3, CacheReadTokens: 11, CacheCreationTokens: 13, Reported: true, CacheCreationReported: true}
	if usage != want {
		t.Fatalf("usage = %+v, want %+v", usage, want)
	}
}

func TestParseAcpxJSONEventsParsesResultUsage(t *testing.T) {
	events := `{"jsonrpc":"2.0","id":1,"result":{"usage":{"input_tokens":21,"output_tokens":8,"cachedReadTokens":5,"cachedWriteTokens":2}}}` + "\n"
	var usage TokenUsage

	_, _, err := parseAcpxJSONEvents(context.Background(), strings.NewReader(events), nil, &usage)
	if err != nil {
		t.Fatalf("parseAcpxJSONEvents() error = %v", err)
	}
	want := TokenUsage{InputTokens: 21, OutputTokens: 8, CacheReadTokens: 5, CacheCreationTokens: 2, Reported: true, CacheCreationReported: true}
	if usage != want {
		t.Fatalf("usage = %+v, want %+v", usage, want)
	}
}

func TestACPAgentRunParsesAcpxJSONOutput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell fixture is Unix-only")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "acpx")
	argLog := filepath.Join(dir, "args.txt")
	t.Setenv("ARG_LOG", argLog)
	contents := `#!/bin/sh
printf '%s\n' "$@" > "$ARG_LOG"
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"usage_update","used":123,"size":1000}}}'
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"{\"done\":true}"}}}}'
`
	if err := os.WriteFile(script, []byte(contents), 0o755); err != nil {
		t.Fatalf("write script: %v", err)
	}

	a, err := New("acp:gemini", script, nil)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	var chunks []string
	result, err := a.Run(context.Background(), RunOpts{
		Prompt:     "do work",
		CWD:        dir,
		JSONSchema: json.RawMessage(`{"type":"object"}`),
		OnChunk:    func(text string) { chunks = append(chunks, text) },
	})
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	var output map[string]bool
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("unmarshal output: %v", err)
	}
	if !output["done"] {
		t.Fatalf("output = %s, want done true", string(result.Output))
	}
	if result.Usage.InputTokens != 123 {
		t.Errorf("input tokens = %d, want 123", result.Usage.InputTokens)
	}
	if len(chunks) != 1 || chunks[0] != `{"done":true}` {
		t.Errorf("chunks = %q", chunks)
	}
	argsData, err := os.ReadFile(argLog)
	if err != nil {
		t.Fatalf("read args: %v", err)
	}
	argsText := string(argsData)
	for _, want := range []string{"--cwd\n" + dir, "--format\njson", "--json-strict", "gemini", "do work"} {
		if !strings.Contains(argsText, want) {
			t.Errorf("args missing %q in:\n%s", want, argsText)
		}
	}
}

func TestNew_Unknown(t *testing.T) {
	_, err := New("nonexistent", "foo", nil)
	if err == nil {
		t.Fatal("expected error for unknown agent")
	}
	if !strings.Contains(err.Error(), "unknown agent") {
		t.Errorf("expected 'unknown agent' in error, got: %v", err)
	}
	if !strings.Contains(err.Error(), string(types.AgentAuto)) {
		t.Errorf("expected auto agent option in error, got: %v", err)
	}
	if !strings.Contains(err.Error(), "config.yaml") {
		t.Errorf("expected config guidance in error, got: %v", err)
	}
}

func TestTokenUsage_Total(t *testing.T) {
	u := TokenUsage{
		InputTokens:         100,
		OutputTokens:        50,
		CacheReadTokens:     20,
		CacheCreationTokens: 10,
	}
	if u.Total() != 150 {
		t.Errorf("expected total 150, got %d", u.Total())
	}
}

func TestTokenUsage_Add(t *testing.T) {
	a := TokenUsage{InputTokens: 100, OutputTokens: 50}
	b := TokenUsage{InputTokens: 200, OutputTokens: 75, CacheReadTokens: 30}
	a.Add(b)
	if a.InputTokens != 300 {
		t.Errorf("expected InputTokens 300, got %d", a.InputTokens)
	}
	if a.OutputTokens != 125 {
		t.Errorf("expected OutputTokens 125, got %d", a.OutputTokens)
	}
	if a.CacheReadTokens != 30 {
		t.Errorf("expected CacheReadTokens 30, got %d", a.CacheReadTokens)
	}
}

func TestFinalizeTextResult_NoSchemaAllowsTextOnly(t *testing.T) {
	result, err := finalizeTextResult("codex", "fixed it", nil, TokenUsage{InputTokens: 1, OutputTokens: 2})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Text != "fixed it" {
		t.Errorf("unexpected text: %q", result.Text)
	}
	if result.Output != nil {
		t.Fatalf("expected nil structured output, got %s", string(result.Output))
	}
	if result.Usage.InputTokens != 1 || result.Usage.OutputTokens != 2 {
		t.Errorf("unexpected usage: %+v", result.Usage)
	}
}

func TestFinalizeTextResult_WithSchemaParsesJSON(t *testing.T) {
	result, err := finalizeTextResult("codex", `{"done":true}`, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output map[string]any
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output["done"] != true {
		t.Errorf("expected done=true, got %v", output["done"])
	}
}

func TestFinalizeTextResult_WithSchemaParsesFencedJSON(t *testing.T) {
	text := "review complete\n\n```json\n{\"done\":true}\n```"
	result, err := finalizeTextResult("codex", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output map[string]any
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output["done"] != true {
		t.Errorf("expected done=true, got %v", output["done"])
	}
	if result.Text != text {
		t.Errorf("expected original text to be preserved, got %q", result.Text)
	}
}

func TestFinalizeTextResult_WithSchemaParsesInlineOpenFence(t *testing.T) {
	// Codex/GPT-5 sometimes glues the opening ```json fence to the end of
	// the prior reasoning line, with no newline between text and backticks.
	text := "thinking about edge cases now.```json\n{\"done\":true}\n```"
	result, err := finalizeTextResult("codex", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output map[string]any
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output["done"] != true {
		t.Errorf("expected done=true, got %v", output["done"])
	}
}

func TestFinalizeTextResult_WithSchemaParsesInlineCloseFence(t *testing.T) {
	// Symmetric case: closing fence immediately follows the JSON with no
	// newline before the backticks.
	text := "prelude\n```json\n{\"done\":true}```"
	result, err := finalizeTextResult("codex", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output map[string]any
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output["done"] != true {
		t.Errorf("expected done=true, got %v", output["done"])
	}
}

func TestFinalizeTextResult_WithSchemaParsesBareJSONAfterText(t *testing.T) {
	// No fence at all: reasoning prose followed by a raw JSON object.
	text := "Here's the review:\n{\"done\":true}"
	result, err := finalizeTextResult("codex", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output map[string]any
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output["done"] != true {
		t.Errorf("expected done=true, got %v", output["done"])
	}
}

func TestFinalizeTextResult_WithSchemaPrefersLastBareJSON(t *testing.T) {
	// If reasoning text embeds a decorative JSON object and the final
	// answer is a separate object at the end, the final one should win.
	text := `I considered {"foo":"bar"} as one option. Final: {"done":true}`
	result, err := finalizeTextResult("codex", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output map[string]any
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output["done"] != true {
		t.Errorf("expected done=true, got %v", output["done"])
	}
}

// commitSummarySchemaShape mirrors the fix-output schema the review fixer,
// test-fix, lint-fix, and rebase agents are validated against
// (internal/pipeline/steps/common_fix.go commitSummarySchema).
var commitSummarySchemaShape = json.RawMessage(`{
	"type":"object",
	"properties":{"summary":{"type":"string"}},
	"required":["summary"]
}`)

// TestFinalizeTextResult_WithSchemaParsesFixOutputWithLeadingProse reproduces
// the integration bug where the pi fix agent (deepseek via pi) emitted leading
// prose before a ```json fenced payload WITHOUT a closing fence, and the
// tolerant extraction bailed on the unclosed opener, surfacing the raw strict
// parse error 'invalid character 'A' looking for beginning of value' and
// killing the review step ("agent fix: pi output parse: ..."). The fence body
// and any later bare object must still be recovered and validated.
func TestFinalizeTextResult_WithSchemaParsesFixOutputWithLeadingProse(t *testing.T) {
	text := "All fixes applied and verified. Summary of the round:\n\n" +
		"- **Validated the finding**: PARITY.md confirms B1 is Claude Code-only (agents + Task tool), B7 excludes Copilot, OpenCode overlay agents are B5/B6, codex exec appears only in B7 so the four cited cells did misattribute phases.\n" +
		"- **Applied option A** in `packages/harness/src/matrix.ts`: dropped `(B1)` from opencode/codex/copilot subagents reasons and `(B7)` from copilot goal-loop reason; kept phase ids on all 12 correctly-attributed cells.\n" +
		"- Verified: `bun test test/f17-matrix.test.ts` returned 24 pass, 0 fail; no other file asserts the edited reason strings.\n\n" +
		"```json\n" +
		`{"summary":"Drop misattributed roadmap phase ids from 4 unsupported-cell reasons"}` + "\n"

	result, err := finalizeTextResult("pi", text, commitSummarySchemaShape, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output map[string]any
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output["summary"] != "Drop misattributed roadmap phase ids from 4 unsupported-cell reasons" {
		t.Errorf("unexpected summary: %v", output["summary"])
	}
}

// TestFinalizeTextResult_WithSchemaTreatsProseFixOutputAsRoundSummary keeps
// fix rounds alive when the fixer ends its round with a plain-text summary
// instead of the requested JSON object. Pi fixers regularly do this, and the
// former hard failure ("agent fix: pi output parse: ...") discarded the
// already-applied fixes before they were committed. The prose is treated as
// the round summary: the round completes and the work gets committed.
func TestFinalizeTextResult_WithSchemaTreatsProseFixOutputAsRoundSummary(t *testing.T) {
	text := "All fixes applied and verified. The summary is: everything looks good now."
	result, err := finalizeTextResult("pi", text, commitSummarySchemaShape, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output struct {
		Summary string `json:"summary"`
	}
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output.Summary != text {
		t.Errorf("expected prose to become the round summary, got %q", output.Summary)
	}
	if result.Text != text {
		t.Errorf("expected original text to be preserved, got %q", result.Text)
	}
}

// TestFinalizeTextResult_WithSchemaMalformedJSONStillFailsLoudly keeps the
// prose fallback honest: text that looks like an attempted JSON payload (a
// leading brace) but does not parse must still fail with a clear error, never
// be silently swallowed as a round summary.
func TestFinalizeTextResult_WithSchemaMalformedJSONStillFailsLoudly(t *testing.T) {
	text := `{"summary": "the fix is applied`
	_, err := finalizeTextResult("pi", text, commitSummarySchemaShape, TokenUsage{})
	if err == nil {
		t.Fatal("expected malformed JSON fix output to fail")
	}
	if !strings.Contains(err.Error(), "output parse") {
		t.Errorf("expected parse error, got: %v", err)
	}
}

// TestFinalizeTextResult_WithSchemaProseBraceFragmentBecomesRoundSummary
// covers realistic fixer prose that contains balanced non-JSON brace
// fragments ("Changed {opencode -> codex} handling in matrix.ts"). The
// fragment is not an attempted JSON payload - it is not parseable JSON and it
// is not fenced - so the round must still complete with the prose synthesized
// as the round summary; failing here would lose the same applied fixes the
// prose fallback exists to protect.
func TestFinalizeTextResult_WithSchemaProseBraceFragmentBecomesRoundSummary(t *testing.T) {
	text := "Changed {opencode -> codex} handling in matrix.ts"
	result, err := finalizeTextResult("pi", text, commitSummarySchemaShape, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output struct {
		Summary string `json:"summary"`
	}
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output.Summary != text {
		t.Errorf("expected prose with brace fragment to become the round summary, got %q", output.Summary)
	}
}

// TestFinalizeTextResult_WithSchemaBareNonObjectPayloadStillFailsLoudly keeps
// the prose fallback from swallowing parseable-but-schema-invalid payloads: a
// bare string is valid JSON that is not a summary object, and a bare object
// missing the required "summary" property is an attempted JSON payload. Both
// must keep failing loudly instead of being synthesized over.
func TestFinalizeTextResult_WithSchemaBareNonObjectPayloadStillFailsLoudly(t *testing.T) {
	for _, text := range []string{`"hello"`, `{"done":true}`} {
		_, err := finalizeTextResult("pi", text, commitSummarySchemaShape, TokenUsage{})
		if err == nil {
			t.Errorf("expected output parse failure for %q", text)
			continue
		}
		if !strings.Contains(err.Error(), "output parse") {
			t.Errorf("expected parse error for %q, got: %v", text, err)
		}
	}
}

// TestFinalizeTextResult_WithSchemaFencedMalformedJSONStaysLoud keeps the
// fenced-payload guard intact: a ```json fence whose body does not parse is
// an attempted JSON payload and must fail loudly, never be synthesized over
// as a round summary.
func TestFinalizeTextResult_WithSchemaFencedMalformedJSONStaysLoud(t *testing.T) {
	text := "Round complete.\n\n```json\n{\"summary\": broken\n```\n"
	_, err := finalizeTextResult("pi", text, commitSummarySchemaShape, TokenUsage{})
	if err == nil {
		t.Fatal("expected fenced malformed JSON to fail")
	}
	if !strings.Contains(err.Error(), "output parse") {
		t.Errorf("expected parse error, got: %v", err)
	}
}

// TestFinalizeTextResult_WithSchemaProseFallbackScopedToSummaryShape proves
// the prose fallback never leaks into structured-output rounds: a findings
// shaped schema (review, lint, test, document) must still fail loudly on
// prose-only output, because there is no single summary string to recover
// and silently approving with zero findings would hide a broken agent.
func TestFinalizeTextResult_WithSchemaProseFallbackScopedToSummaryShape(t *testing.T) {
	text := "I reviewed the diff and everything looks good."
	_, err := finalizeTextResult("pi", text, reviewFindingsSchemaShape, TokenUsage{})
	if err == nil {
		t.Fatal("expected prose-only review output to fail")
	}
	if !strings.Contains(err.Error(), "output parse") {
		t.Errorf("expected parse error, got: %v", err)
	}
}

// TestFinalizeTextResult_WithSchemaProseSummaryCappedToSchemaMaxLength keeps
// a synthesized prose summary within the schema's declared summary bound, so
// the downstream commit-summary byte limit never rejects a round the parser
// already accepted.
func TestFinalizeTextResult_WithSchemaProseSummaryCappedToSchemaMaxLength(t *testing.T) {
	schema := json.RawMessage(`{
		"type":"object",
		"properties":{"summary":{"type":"string","maxLength":32}},
		"required":["summary"]
	}`)
	text := "This is a very long plain-text round summary that goes well beyond the declared summary length bound."
	result, err := finalizeTextResult("pi", text, schema, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output struct {
		Summary string `json:"summary"`
	}
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if len(output.Summary) > 32 {
		t.Errorf("synthesized summary length = %d, want <= 32", len(output.Summary))
	}
}

// TestFinalizeTextResult_WithSchemaFixOutputStaysStrictAfterExtraction keeps
// strict schema validation on the EXTRACTED object: an unclosed ```json fence
// whose payload misses the required "summary" field must still be rejected.
func TestFinalizeTextResult_WithSchemaFixOutputStaysStrictAfterExtraction(t *testing.T) {
	text := "All fixes applied.\n\n```json\n" + `{"done":true}` + "\n"
	_, err := finalizeTextResult("pi", text, commitSummarySchemaShape, TokenUsage{})
	if err == nil {
		t.Fatal("expected extracted fix output missing required summary to fail")
	}
	if !strings.Contains(err.Error(), "missing required field") {
		t.Errorf("expected required-field validation error, got: %v", err)
	}
}

// reviewFindingsSchemaShape mirrors the review output schema validated for
// the review step (internal/pipeline/steps/common.go reviewFindingsSchema),
// including the PR #7 schema defaults for action/review_scope.
var reviewFindingsSchemaShape = json.RawMessage(`{
	"type": "object",
	"properties": {
		"findings": {
			"type": "array",
			"items": {
				"type": "object",
				"properties": {
					"severity": {"type": "string", "enum": ["error", "warning", "info"]},
					"description": {"type": "string"},
					"action": {"type": "string", "enum": ["no-op", "auto-fix", "ask-user"], "default": "no-op"},
					"review_scope": {"type": "string", "enum": ["source", "pipeline-owned-delivery", "external-delivery"], "default": "source"}
				},
				"required": ["severity", "description", "action", "review_scope"]
			}
		},
		"risk_level": {"type": "string", "enum": ["low", "medium", "high"]},
		"risk_rationale": {"type": "string"},
		"risk_scope": {"type": "string", "enum": ["source-or-external", "pipeline-owned-delivery"]}
	},
	"required": ["findings", "risk_level", "risk_rationale", "risk_scope"]
}`)

// TestFinalizeTextResult_WithSchemaParsesReviewOutputWithLeadingProseAndInlineFenceMention
// reproduces the review-path failure: the pi review agent emitted a full prose
// pass that itself mentions ```json fences inline ("when a ` ```json `
// opener had no closer") followed by a properly CLOSED ```json fence with the
// findings payload. The inline mention was mistaken for a fence opener, and
// the block-skip logic then swallowed the real fence, surfacing the raw
// strict-parse error ('invalid character 'I' looking for beginning of
// value'). The shared extractor must skip only the inline mention and still
// recover the fenced payload, feeding it through the schema-defaults
// validator (PR #7 contract: a finding that omits action/review_scope is
// completed from the schema; fields the agent provided stay strict).
func TestFinalizeTextResult_WithSchemaParsesReviewOutputWithLeadingProseAndInlineFenceMention(t *testing.T) {
	text := "I've completed a full review pass. Let me summarize my verification before returning the structured result:\n\n" +
		"1. **Root cause confirmed**: in the pre-fix code, `fencedJSONCandidates` returned an empty candidate list when a ` ```json ` opener had no closer, and `lastBareJSONObject` `break`-ed the entire scan at any unclosed fence opener.\n" +
		"2. **Fix correctness**: traced all three new tests through the code.\n\n" +
		"```json\n" +
		"{\n" +
		"  \"findings\": [\n" +
		"    {\"id\":\"F1\",\"severity\":\"warning\",\"description\":\"possible nil deref\"}\n" +
		"  ],\n" +
		"  \"risk_level\": \"low\",\n" +
		"  \"risk_rationale\": \"well-bounded change\",\n" +
		"  \"risk_scope\": \"source-or-external\"\n" +
		"}\n" +
		"```\n"

	result, err := finalizeTextResult("pi", text, reviewFindingsSchemaShape, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output struct {
		Findings []struct {
			Severity string `json:"severity"`
			Action   string `json:"action"`
		} `json:"findings"`
		RiskLevel string `json:"risk_level"`
	}
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if len(output.Findings) != 1 {
		t.Fatalf("expected 1 finding, got %d", len(output.Findings))
	}
	// The schema-defaults contract (PR #7): the agent omitted action and
	// review_scope, so the extractor must complete them from the schema.
	if output.Findings[0].Action != "no-op" {
		t.Errorf("expected defaulted action=no-op, got %q", output.Findings[0].Action)
	}
	if output.RiskLevel != "low" {
		t.Errorf("expected risk_level=low, got %q", output.RiskLevel)
	}
}

// TestFinalizeTextResult_WithSchemaParsesReviewOutputWithLineFinalBacktickMention
// reproduces the second review-path failure shape: the pi review agent's prose
// itself demonstrates a line-final inline mention "` ```json`" (backtick
// immediately before the run, whitespace-free info) followed by a real,
// properly closed ```json fence with the findings payload. The mention was
// misclassified as a real fence opener and the block-skip swallowed the real
// fence, surfacing 'invalid character 'I' looking for beginning of value'.
// A fence opener preceded by a backtick - or whose single-token info carries
// a backtick - is inline code, not a fence block.
func TestFinalizeTextResult_WithSchemaParsesReviewOutputWithLineFinalBacktickMention(t *testing.T) {
	text := "I've completed a full review pass. Let me summarize my analysis:\n\n" +
		"**One residual finding:** a line-final mention like \"` ```json`\" is misclassified as a real fence and skipFenceBlock depth-counts a later real ```json fence + its closer as a nested block, so the payload is swallowed. Concrete path: text = \"The scanner saw ` ```json`\n```json\n{\"done\":true}\n```\".\n\n" +
		"```json\n" +
		"{\n" +
		"  \"findings\": [\n" +
		"    {\"severity\":\"info\",\"description\":\"residual shape noted\"}\n" +
		"  ],\n" +
		"  \"risk_level\": \"low\",\n" +
		"  \"risk_rationale\": \"well-bounded\",\n" +
		"  \"risk_scope\": \"source-or-external\"\n" +
		"}\n" +
		"```\n"

	result, err := finalizeTextResult("pi", text, reviewFindingsSchemaShape, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output struct {
		Findings []struct {
			Severity string `json:"severity"`
		} `json:"findings"`
		RiskLevel string `json:"risk_level"`
	}
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if len(output.Findings) != 1 || output.Findings[0].Severity != "info" {
		t.Errorf("unexpected findings: %+v", output.Findings)
	}
	if output.RiskLevel != "low" {
		t.Errorf("expected risk_level=low, got %q", output.RiskLevel)
	}
}

func TestFinalizeTextResult_WithSchemaRejectsBareJSONMissingRequiredKeys(t *testing.T) {
	text := `I inspected the diff and found no issues. {"foo":"bar"}`
	schema := json.RawMessage(`{
		"type":"object",
		"properties":{
			"findings":{"type":"array"},
			"summary":{"type":"string"}
		},
		"required":["findings","summary"]
	}`)

	_, err := finalizeTextResult("codex", text, schema, TokenUsage{})
	if err == nil {
		t.Fatal("expected bare JSON missing required keys to fail")
	}
}

func TestFinalizeTextResult_WithSchemaRejectsNestedEnumViolations(t *testing.T) {
	text := `review complete {"findings":[{"severity":"fatal","description":"x","action":"fix-it"}],"summary":"1 issue"}`
	schema := json.RawMessage(`{
		"type":"object",
		"properties":{
			"findings":{
				"type":"array",
				"items":{
					"type":"object",
					"properties":{
						"severity":{"type":"string","enum":["error","warning","info"]},
						"description":{"type":"string"},
						"action":{"type":"string","enum":["auto-fix","ask-user","no-op"]}
					},
					"required":["severity","description","action"]
				}
			},
			"summary":{"type":"string"}
		},
		"required":["findings","summary"]
	}`)

	_, err := finalizeTextResult("codex", text, schema, TokenUsage{})
	if err == nil {
		t.Fatal("expected nested enum violation to fail")
	}
}

func TestFinalizeTextResult_WithSchemaAllowsNullOptionalFieldsInTextFallback(t *testing.T) {
	text := `{"findings":[{"severity":"warning","file":null,"line":null,"description":"x","action":"auto-fix"}],"summary":"1 issue"}`
	schema := json.RawMessage(`{
		"type":"object",
		"properties":{
			"findings":{
				"type":"array",
				"items":{
					"type":"object",
					"properties":{
						"severity":{"type":"string","enum":["error","warning","info"]},
						"file":{"type":"string"},
						"line":{"type":"integer"},
						"description":{"type":"string"},
						"action":{"type":"string","enum":["no-op","auto-fix","ask-user"]}
					},
					"required":["severity","description","action"]
				}
			},
			"summary":{"type":"string"}
		},
		"required":["findings","summary"]
	}`)

	result, err := finalizeTextResult("opencode", text, schema, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if string(result.Output) != text {
		t.Fatalf("unexpected output: %s", string(result.Output))
	}
}

// findingsDefaultsSchema mirrors the pipeline's findings-item schema: action is
// required but carries a "no-op" default, review_scope is required but carries a
// "source" default. It reproduces the shape the pi adapter's review output is
// validated against (internal/pipeline/steps/common.go).
var findingsDefaultsSchema = json.RawMessage(`{
	"type":"object",
	"properties":{
		"findings":{
			"type":"array",
			"items":{
				"type":"object",
				"properties":{
					"severity":{"type":"string","enum":["error","warning","info"]},
					"file":{"type":"string"},
					"line":{"type":"integer"},
					"description":{"type":"string"},
					"action":{"type":"string","enum":["no-op","auto-fix","ask-user"],"default":"no-op"},
					"review_scope":{"type":"string","enum":["source","pipeline-owned-delivery","external-delivery"],"default":"source"}
				},
				"required":["severity","description","action","review_scope"]
			}
		},
		"summary":{"type":"string"}
	},
	"required":["findings","summary"]
}`)

func TestFinalizeTextResult_WithSchemaDefaultsMissingActionToNoOp(t *testing.T) {
	// Regression: the pi agent (deepseek via pi) produced well-reasoned review
	// findings that omitted "action", and the strict validator killed the gate.
	// A finding without action must now parse with the schema default "no-op"
	// instead of failing with "missing required field".
	text := `{"findings":[{"severity":"warning","description":"possible nil dereference"}],"summary":"1 issue"}`

	result, err := finalizeTextResult("pi", text, findingsDefaultsSchema, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var parsed struct {
		Findings []struct {
			Severity string `json:"severity"`
			Action   string `json:"action"`
		} `json:"findings"`
	}
	if err := json.Unmarshal(result.Output, &parsed); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if len(parsed.Findings) != 1 {
		t.Fatalf("expected 1 finding, got %d", len(parsed.Findings))
	}
	if parsed.Findings[0].Action != "no-op" {
		t.Errorf("expected defaulted action=no-op, got %q", parsed.Findings[0].Action)
	}
}

func TestFinalizeTextResult_WithSchemaDefaultsMissingReviewScopeToSource(t *testing.T) {
	// Regression: a review finding without review_scope must parse with the
	// schema default "source" instead of failing.
	text := `{"findings":[{"severity":"error","description":"secret in log","action":"auto-fix"}],"summary":"1 issue"}`

	result, err := finalizeTextResult("pi", text, findingsDefaultsSchema, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var parsed struct {
		Findings []struct {
			Action      string `json:"action"`
			ReviewScope string `json:"review_scope"`
		} `json:"findings"`
	}
	if err := json.Unmarshal(result.Output, &parsed); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if len(parsed.Findings) != 1 {
		t.Fatalf("expected 1 finding, got %d", len(parsed.Findings))
	}
	if parsed.Findings[0].Action != "auto-fix" {
		t.Errorf("expected present action preserved, got %q", parsed.Findings[0].Action)
	}
	if parsed.Findings[0].ReviewScope != "source" {
		t.Errorf("expected defaulted review_scope=source, got %q", parsed.Findings[0].ReviewScope)
	}
}

func TestFinalizeTextResult_WithSchemaDefaultsDoNotMaskEnumViolations(t *testing.T) {
	// Defaults fill missing fields only; a present field that violates the enum
	// must still fail strict validation.
	text := `{"findings":[{"severity":"fatal","description":"x","action":"fix-it"}],"summary":"1 issue"}`

	_, err := finalizeTextResult("pi", text, findingsDefaultsSchema, TokenUsage{})
	if err == nil {
		t.Fatal("expected enum violation to fail despite schema defaults")
	}
}

func TestFinalizeTextResult_WithSchemaDefaultsUnchangedWhenNoneDeclared(t *testing.T) {
	// A schema without "default" annotations must leave output byte-for-byte
	// unchanged (no re-marshaling, no key reordering).
	text := `{"findings":[{"severity":"warning","description":"x","action":"auto-fix"}],"summary":"1 issue"}`
	schema := json.RawMessage(`{
		"type":"object",
		"properties":{
			"findings":{
				"type":"array",
				"items":{
					"type":"object",
					"properties":{
						"severity":{"type":"string"},
						"description":{"type":"string"},
						"action":{"type":"string"}
					},
					"required":["severity","description","action"]
				}
			},
			"summary":{"type":"string"}
		},
		"required":["findings","summary"]
	}`)

	result, err := finalizeTextResult("codex", text, schema, TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if string(result.Output) != text {
		t.Fatalf("output changed without declared defaults: %s", string(result.Output))
	}
}

func TestFinalizeTextResult_WithSchemaParsesCodexRealWorldOutput(t *testing.T) {
	// Regression: real codex output from pipeline 01KPYD4SD644SR9JCNX6Y.
	// Reasoning sentences were concatenated with no newlines, and the
	// opening ```json fence was glued to the end of the last sentence.
	text := "Reviewing the diff between `ba90e3c` and `6fdb361` first.I'm reading the patch now.I'm down to edge cases: timer semantics after multiple `result` events.```json\n" +
		"{\n" +
		"  \"findings\": [],\n" +
		"  \"risk_assessment\": {\n" +
		"    \"risk_level\": \"low\",\n" +
		"    \"risk_rationale\": \"clean\"\n" +
		"  }\n" +
		"}\n" +
		"```"
	result, err := finalizeTextResult("codex", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var output struct {
		Findings       []any `json:"findings"`
		RiskAssessment struct {
			RiskLevel string `json:"risk_level"`
		} `json:"risk_assessment"`
	}
	if err := json.Unmarshal(result.Output, &output); err != nil {
		t.Fatalf("failed to parse output: %v", err)
	}
	if output.RiskAssessment.RiskLevel != "low" {
		t.Errorf("expected risk_level=low, got %q", output.RiskAssessment.RiskLevel)
	}
}

func TestFinalizeTextResult_WithSchemaRejectsAmbiguousFencedJSON(t *testing.T) {
	text := strings.Join([]string{
		"```json",
		`{"first":true}`,
		"```",
		"```json",
		`{"second":true}`,
		"```",
	}, "\n")
	_, err := finalizeTextResult("codex", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err == nil {
		t.Fatal("expected ambiguous fenced JSON to fail")
	}
	if !strings.Contains(err.Error(), "multiple JSON code fences") {
		t.Fatalf("expected multiple JSON code fences error, got %v", err)
	}
}

func TestFencedJSONCandidates_IgnoreBackticksInsideJSONString(t *testing.T) {
	text := "review complete\n```json\n{\"summary\":\"quoted ```snippet``` in markdown\",\"findings\":[]}\n```\npostlude"

	got := fencedJSONCandidates(text)
	if len(got) != 1 {
		t.Fatalf("expected 1 candidate, got %d", len(got))
	}
	want := "{\"summary\":\"quoted ```snippet``` in markdown\",\"findings\":[]}\n"
	if got[0] != want {
		t.Fatalf("candidate = %q, want %q", got[0], want)
	}
}

func TestFencedJSONCandidates_AllowIndentedClosingFence(t *testing.T) {
	text := "review complete\n```json\n{\"summary\":\"ok\",\"findings\":[]}\n   ```\nnext paragraph"

	got := fencedJSONCandidates(text)
	if len(got) != 1 {
		t.Fatalf("expected 1 candidate, got %d", len(got))
	}
	want := "{\"summary\":\"ok\",\"findings\":[]}\n"
	if got[0] != want {
		t.Fatalf("candidate = %q, want %q", got[0], want)
	}
}

func TestFinalizeTextResult_WithSchemaIgnoresJSONInsideNonJSONFence(t *testing.T) {
	text := strings.Join([]string{
		"Reasoning follows.",
		"```markdown",
		"Example output:",
		"```json",
		`{"done":true}`,
		"```",
		"```",
		"Final answer: not valid JSON",
	}, "\n")

	if got := fencedJSONCandidates(text); len(got) != 0 {
		t.Fatalf("expected no fenced JSON candidates, got %q", got)
	}

	_, err := finalizeTextResult("codex", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err == nil {
		t.Fatal("expected parse failure")
	}
}

func TestFinalizeTextResult_ParseErrorIncludesOutputSnippet(t *testing.T) {
	text := "Now I've applied all four fixes and verified the build passes."
	_, err := finalizeTextResult("copilot", text, json.RawMessage(`{"type":"object"}`), TokenUsage{})
	if err == nil {
		t.Fatal("expected parse failure on prose output")
	}
	if !strings.Contains(err.Error(), "output snippet:") {
		t.Errorf("error should include an output snippet, got %v", err)
	}
	if !strings.Contains(err.Error(), "Now I've applied") {
		t.Errorf("error should embed the offending text, got %v", err)
	}
}

func TestOutputSnippet_TruncatesLongText(t *testing.T) {
	long := strings.Repeat("x", 500)
	got := outputSnippet(long)
	if !strings.HasSuffix(got, "…") {
		t.Errorf("expected ellipsis suffix on truncated snippet, got %q", got)
	}
	if runes := []rune(got); len(runes) != 201 {
		t.Errorf("expected 200 runes plus ellipsis, got %d runes", len(runes))
	}
}
