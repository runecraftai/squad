package agent

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
)

// countingPolicy records how often a run imports its confined Git result.
type countingPolicy struct {
	syncs    atomic.Int64
	syncErr  error
	commands atomic.Int64
}

func (p *countingPolicy) Command(*exec.Cmd) error {
	p.commands.Add(1)
	return nil
}

func (p *countingPolicy) Sync() error {
	p.syncs.Add(1)
	return p.syncErr
}

func (p *countingPolicy) OnClose(func()) error { return nil }

// serverPoolServing hands srv to runs launched under policy, so the adapter
// reaches the mock server instead of spawning a real one.
func serverPoolServing(policy ProcessExecutionPolicy, srv *managedServer) serverPool {
	return serverPool{servers: map[ProcessExecutionPolicy]*managedServer{policy: srv}}
}

func opencodeStructuredServer(t *testing.T) *httptest.Server {
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

func TestOpencodeAgentImportsConfinedResultAfterEachRun(t *testing.T) {
	server := opencodeStructuredServer(t)
	policy := &countingPolicy{}
	a := &opencodeAgent{bin: "opencode", servers: serverPoolServing(policy, &managedServer{port: mustParsePort(server.URL)})}

	if _, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy}); err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	if got := policy.syncs.Load(); got != 1 {
		t.Fatalf("confined result syncs after one run = %d, want 1", got)
	}
	if _, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy}); err != nil {
		t.Fatalf("second Run() error = %v", err)
	}
	if got := policy.syncs.Load(); got != 2 {
		t.Fatalf("confined result syncs after two runs = %d, want 2", got)
	}
}

func TestOpencodeAgentFailsRunWhenConfinedResultCannotBeImported(t *testing.T) {
	server := opencodeStructuredServer(t)
	policy := &countingPolicy{syncErr: errors.New("host and private Git histories diverged")}
	a := &opencodeAgent{bin: "opencode", servers: serverPoolServing(policy, &managedServer{port: mustParsePort(server.URL)})}

	result, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy})
	if err == nil {
		t.Fatal("run succeeded although its confined result could not be imported")
	}
	if !strings.Contains(err.Error(), "host and private Git histories diverged") {
		t.Fatalf("Run() error = %v, want the import failure", err)
	}
	if result != nil {
		t.Fatalf("failed run reported a result: %+v", result)
	}
}

func rovodevStructuredServer(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v3/sessions/create" && r.Method == http.MethodPost:
			fmt.Fprint(w, `{"session_id":"sync-session"}`)
		case r.URL.Path == "/v3/set_chat_message" && r.Method == http.MethodPost:
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/v3/stream_chat" && r.Method == http.MethodGet:
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

func TestRovodevAgentImportsConfinedResultAfterEachRun(t *testing.T) {
	server := rovodevStructuredServer(t)
	policy := &countingPolicy{}
	a := &rovodevAgent{bin: "acli", servers: serverPoolServing(policy, &managedServer{port: mustParsePort(server.URL)})}

	for run := 1; run <= 2; run++ {
		if _, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy}); err != nil {
			t.Fatalf("Run() #%d error = %v", run, err)
		}
		if got := policy.syncs.Load(); got != int64(run) {
			t.Fatalf("confined result syncs after %d run(s) = %d", run, got)
		}
	}
}

func TestRovodevAgentFailsRunWhenConfinedResultCannotBeImported(t *testing.T) {
	server := rovodevStructuredServer(t)
	policy := &countingPolicy{syncErr: errors.New("host and private Git histories diverged")}
	a := &rovodevAgent{bin: "acli", servers: serverPoolServing(policy, &managedServer{port: mustParsePort(server.URL)})}

	result, err := a.Run(context.Background(), RunOpts{CWD: t.TempDir(), Prompt: "review", ExecutionPolicy: policy})
	if err == nil {
		t.Fatal("run succeeded although its confined result could not be imported")
	}
	if result != nil {
		t.Fatalf("failed run reported a result: %+v", result)
	}
}
