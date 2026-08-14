package agent

import (
	"context"
	"fmt"
	"strings"
	"sync"
)

// opencodeAgent starts a persistent HTTP server via `opencode serve`
// and sends requests via REST with SSE streaming.
type opencodeAgent struct {
	bin       string
	extraArgs []string
	mu        sync.Mutex
	server    *managedServer
}

func (a *opencodeAgent) Name() string { return "opencode" }

// SupportsSessionResume reports opencode's native durable-session capability:
// sessions hosted by the managed `opencode serve` accept repeated POST
// /session/{id}/message turns, so one session identity can span fixer rounds
// (verified empirically against the installed opencode server: a second
// message to the same session id recalls context stored by the first, and a
// message to an unknown id fails with NotFoundError so a stale resume drops
// to the pipeline's fresh-session fallback).
func (a *opencodeAgent) SupportsSessionResume() bool { return true }

func (a *opencodeAgent) ReportsAgentAttempts() bool { return true }

func (a *opencodeAgent) Run(ctx context.Context, opts RunOpts) (*Result, error) {
	return runWithRetry(ctx, "opencode", opts, claudeMaxRetries, classifyTransient, a.recoverTransientRetry, func() (*Result, error) {
		return a.runOnce(ctx, opts)
	})
}

func (a *opencodeAgent) recoverTransientRetry(label string) {
	if label != "connection refused" {
		return
	}
	a.mu.Lock()
	srv := a.server
	a.server = nil
	a.mu.Unlock()
	if srv != nil {
		srv.shutdown()
	}
}

func (a *opencodeAgent) runOnce(ctx context.Context, opts RunOpts) (*Result, error) {
	// Start server on first invocation (synchronized)
	baseURL, err := a.ensureServer(ctx, opts.CWD)
	if err != nil {
		return nil, err
	}

	// Reuse the durable fixer session when session reuse is active: resume the
	// stored identity when present, otherwise create a session and keep it
	// alive across fixer rounds. Cold invocations keep the legacy lifecycle
	// (create, run, delete).
	resumeID := ""
	reuse := opts.Session != nil
	if reuse {
		resumeID = opts.Session.ID
	}
	sessionID := resumeID
	if sessionID == "" {
		sessionID, err = a.createSession(ctx, baseURL, opts.CWD)
		if err != nil {
			return nil, err
		}
	}
	if !reuse {
		defer a.deleteSession(baseURL, sessionID)
	}

	// Build prompt with schema instructions if provided
	prompt := opts.Prompt
	if len(opts.JSONSchema) > 0 {
		prompt = buildOpencodePrompt(prompt, opts.JSONSchema)
	}

	// Connect to SSE event stream
	streamCtx, streamCancel := context.WithCancel(ctx)
	defer streamCancel()

	eventBody, err := a.connectEventStream(streamCtx, baseURL)
	if err != nil {
		return nil, err
	}
	defer eventBody.Close()

	// Send message concurrently — blocks until agent completes
	type messageResult struct {
		resp *opencodeMessageResponse
		err  error
	}
	msgCtx, msgCancel := context.WithCancel(ctx)
	defer msgCancel()
	msgCh := make(chan messageResult, 1)
	go func() {
		resp, err := a.sendMessage(msgCtx, baseURL, sessionID, prompt, opts.JSONSchema)
		msgCh <- messageResult{resp: resp, err: err}
	}()

	// Process SSE events until session.idle
	state := &opencodeStreamState{
		sessionID:  sessionID,
		onChunk:    opts.OnChunk,
		textParts:  make(map[string]*opencodeTextPart),
		usageByMsg: make(map[string]TokenUsage),
	}
	err = parseOpencodeSSE(eventBody, state)
	streamCancel()

	if err != nil {
		// Check if message request failed
		select {
		case mr := <-msgCh:
			if mr.err != nil {
				return nil, fmt.Errorf("opencode message: %w", mr.err)
			}
		default:
		}
		a.abortSession(baseURL, sessionID)
		return nil, fmt.Errorf("opencode events: %w", err)
	}

	// Wait for message response
	mr := <-msgCh
	if mr.err != nil {
		return nil, fmt.Errorf("opencode message: %w", mr.err)
	}

	// Update usage and text from message response
	responseText := ""
	responseFinalText := ""
	if mr.resp != nil && mr.resp.Info != nil {
		streamedText := state.lastText
		streamedFinalText := state.lastFinalText
		emitResponseChunk := func(chunk string) {
			if opts.OnChunk == nil || chunk == "" {
				return
			}
			state.emitSeparatorIfNeeded()
			opts.OnChunk(chunk)
			state.hasEmittedText = true
		}
		if mr.resp.Info.Role == "assistant" && mr.resp.Info.Tokens != nil {
			state.usageByMsg[mr.resp.Info.ID] = opencodeTokensToUsage(mr.resp.Info.Tokens)
			state.usage = accumulateUsage(state.usageByMsg)
		}
		for _, part := range mr.resp.Parts {
			if part.Type != "text" || strings.TrimSpace(part.Text) == "" {
				continue
			}
			responseText += part.Text
			if part.Metadata != nil && part.Metadata.OpenAI != nil && part.Metadata.OpenAI.Phase == "final_answer" {
				responseFinalText += part.Text
			}
		}
		if responseText != "" {
			state.lastText = responseText
		}
		if responseFinalText != "" {
			state.lastFinalText = responseFinalText
		}
		if responseFinalText != "" {
			responseText = responseFinalText
		}
		if opts.OnChunk != nil && responseText != "" {
			streamedResponseText := streamedText
			if streamedFinalText != "" {
				streamedResponseText = streamedFinalText
			}
			switch {
			case !state.hasEmittedText:
				emitResponseChunk(responseText)
			case streamedResponseText == "":
				emitResponseChunk(responseText)
			case strings.HasPrefix(responseText, streamedResponseText):
				suffix := responseText[len(streamedResponseText):]
				emitResponseChunk(suffix)
			}
		}
	}

	// Prefer structured output from response
	if mr.resp != nil && mr.resp.Info != nil && mr.resp.Info.Structured != nil {
		res := &Result{
			Output:                mr.resp.Info.Structured,
			Text:                  state.lastText,
			Usage:                 state.usage,
			UsageReported:         state.usage.Reported,
			CacheCreationReported: state.usage.CacheCreationReported,
		}
		if reuse {
			// Only reuse invocations report a session identity: cold runs
			// delete their session before the result is consumed, so reporting
			// its id would be a lie to the reuse machinery.
			res.SessionID = sessionID
			res.Resumed = resumeID != ""
		}
		return res, nil
	}

	// Surface opencode's StructuredOutputError directly. When the model
	// fails to call the StructuredOutput tool after the configured retries,
	// opencode sets info.error.name = "StructuredOutputError" and the
	// streamed text is just reasoning prose - feeding it to
	// finalizeTextResult produces the misleading "invalid character 'N'
	// looking for beginning of value" error.
	if mr.resp != nil && mr.resp.Info != nil && mr.resp.Info.Error.IsStructuredOutput() {
		retries := 0
		if mr.resp.Info.Error.Retries != nil {
			retries = *mr.resp.Info.Error.Retries
		}
		return nil, fmt.Errorf("opencode structured output failed after %d internal retries: %s",
			retries, mr.resp.Info.Error.Message)
	}

	// Fall back to parsing JSON from text
	outputText := state.lastFinalText
	if outputText == "" {
		outputText = state.lastText
	}
	res, err := finalizeTextResult("opencode", outputText, opts.JSONSchema, state.usage)
	if res != nil && reuse {
		res.SessionID = sessionID
		res.Resumed = resumeID != ""
	}
	return res, err
}

func (a *opencodeAgent) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.server != nil {
		a.server.shutdown()
		a.server = nil
	}
	return nil
}
