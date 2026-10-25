package agent

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"sync"
	"testing"
)

// gitModelPolicy mirrors the head reconciliation of the run-scoped execution
// policy, so adapter tests can drive host-side and sandbox-side commits and
// observe whether the confined Git stayed importable.
type gitModelPolicy struct {
	mu      sync.Mutex
	parents map[string]string
	host    string
	private string
	synced  string
	seq     int
	syncErr error
}

func newGitModelPolicy() *gitModelPolicy {
	return &gitModelPolicy{parents: map[string]string{"c0": ""}, host: "c0", private: "c0", synced: "c0"}
}

func (p *gitModelPolicy) Command(*exec.Cmd) error { return nil }
func (p *gitModelPolicy) OnClose(func()) error    { return nil }

func (p *gitModelPolicy) isAncestorLocked(ancestor, head string) bool {
	for head != "" {
		if ancestor == head {
			return true
		}
		head = p.parents[head]
	}
	return false
}

func (p *gitModelPolicy) commitLocked(parent string) string {
	p.seq++
	id := fmt.Sprintf("c%d", p.seq)
	p.parents[id] = parent
	return id
}

func (p *gitModelPolicy) Sync() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.syncErr != nil {
		return p.syncErr
	}
	if p.private == p.host {
		p.synced = p.host
		return nil
	}
	if p.isAncestorLocked(p.private, p.host) {
		p.private, p.synced = p.host, p.host
		return nil
	}
	if !p.isAncestorLocked(p.host, p.private) {
		if p.private != p.synced {
			return errors.New("host and private Git histories diverged")
		}
		p.private, p.synced = p.host, p.host
		return nil
	}
	p.host, p.synced = p.private, p.private
	return nil
}

// agentCommit records a commit the confined agent makes on its private head.
func (p *gitModelPolicy) agentCommit() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.private = p.commitLocked(p.private)
}

// pipelineCommit records a host-side pipeline commit, such as the fix
// pipeline committing an agent's work between two fixer rounds.
func (p *gitModelPolicy) pipelineCommit() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.host = p.commitLocked(p.host)
	return p.host
}

func (p *gitModelPolicy) parentOf(commit string) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.parents[commit]
}

func (p *gitModelPolicy) heads() (host, private string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.host, p.private
}

// serverPoolServing hands srv to runs launched under policy, so the adapter
// reaches the mock server instead of spawning a real one.
func serverPoolServing(policy ProcessExecutionPolicy, srv *managedServer) serverPool {
	return serverPool{servers: map[ProcessExecutionPolicy]*managedServer{policy: srv}}
}

func opencodeStructuredServer(t *testing.T, onMessage func()) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/session" && r.Method == http.MethodPost:
			fmt.Fprint(w, `{"id":"sync-session"}`)
		case r.URL.Path == "/global/event" && r.Method == http.MethodGet:
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, "data: {\"payload\":{\"type\":\"session.idle\"}}\n\n")
		case r.URL.Path == "/session/sync-session/message" && r.Method == http.MethodPost:
			if onMessage != nil {
				onMessage()
			}
			fmt.Fprint(w, `{"info":{"id":"msg1","role":"assistant","structured":{"success":true}},"parts":[]}`)
		case r.URL.Path == "/session/sync-session" && r.Method == http.MethodDelete:
			w.WriteHeader(http.StatusOK)
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func TestOpencodeAgentKeepsConfinedGitImportableAcrossRuns(t *testing.T) {
	policy := newGitModelPolicy()
	server := opencodeStructuredServer(t, policy.agentCommit)
	a := &opencodeAgent{bin: "opencode", servers: serverPoolServing(policy, &managedServer{port: mustParsePort(server.URL)})}

	if _, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy}); err != nil {
		t.Fatalf("first Run() error = %v", err)
	}
	pipelineCommit := policy.pipelineCommit()
	if _, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy}); err != nil {
		t.Fatalf("second Run() after a host-side commit: %v", err)
	}

	host, private := policy.heads()
	if host != private {
		t.Fatalf("host head %s and private head %s diverged", host, private)
	}
	if got := policy.parentOf(host); got != pipelineCommit {
		t.Fatalf("second run's agent commit landed on %s, want the pipeline commit %s", got, pipelineCommit)
	}
}

func TestOpencodeAgentFailsRunWhenConfinedGitCannotBeAligned(t *testing.T) {
	policy := newGitModelPolicy()
	policy.syncErr = errors.New("host and private Git histories diverged")
	server := opencodeStructuredServer(t, nil)
	a := &opencodeAgent{bin: "opencode", servers: serverPoolServing(policy, &managedServer{port: mustParsePort(server.URL)})}

	result, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy})
	if err == nil {
		t.Fatal("run succeeded although its confined Git could not be aligned")
	}
	if result != nil {
		t.Fatalf("failed run reported a result: %+v", result)
	}
}

func rovodevStructuredServer(t *testing.T, onStream func()) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v3/sessions/create" && r.Method == http.MethodPost:
			fmt.Fprint(w, `{"session_id":"sync-session"}`)
		case r.URL.Path == "/v3/set_chat_message" && r.Method == http.MethodPost:
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/v3/stream_chat" && r.Method == http.MethodGet:
			if onStream != nil {
				onStream()
			}
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, "event: part_start\ndata: {\"index\":0,\"part\":{\"content\":\"all good\",\"part_kind\":\"text\"},\"event_kind\":\"part_start\"}\n\n")
		case r.URL.Path == "/v3/sessions/sync-session" && r.Method == http.MethodDelete:
			w.WriteHeader(http.StatusOK)
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func TestRovodevAgentKeepsConfinedGitImportableAcrossRuns(t *testing.T) {
	policy := newGitModelPolicy()
	server := rovodevStructuredServer(t, policy.agentCommit)
	a := &rovodevAgent{bin: "acli", servers: serverPoolServing(policy, &managedServer{port: mustParsePort(server.URL)})}

	if _, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy}); err != nil {
		t.Fatalf("first Run() error = %v", err)
	}
	pipelineCommit := policy.pipelineCommit()
	if _, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy}); err != nil {
		t.Fatalf("second Run() after a host-side commit: %v", err)
	}

	host, private := policy.heads()
	if host != private {
		t.Fatalf("host head %s and private head %s diverged", host, private)
	}
	if got := policy.parentOf(host); got != pipelineCommit {
		t.Fatalf("second run's agent commit landed on %s, want the pipeline commit %s", got, pipelineCommit)
	}
}

func TestRovodevAgentFailsRunWhenConfinedGitCannotBeAligned(t *testing.T) {
	policy := newGitModelPolicy()
	policy.syncErr = errors.New("host and private Git histories diverged")
	server := rovodevStructuredServer(t, nil)
	a := &rovodevAgent{bin: "acli", servers: serverPoolServing(policy, &managedServer{port: mustParsePort(server.URL)})}

	result, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy})
	if err == nil {
		t.Fatal("run succeeded although its confined Git could not be aligned")
	}
	if result != nil {
		t.Fatalf("failed run reported a result: %+v", result)
	}
}
