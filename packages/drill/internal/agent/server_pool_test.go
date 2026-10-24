package agent

import (
	"errors"
	"os/exec"
	"sync"
	"testing"
)

type lifecyclePolicy struct {
	mu     sync.Mutex
	stops  []func()
	closed bool
}

func (p *lifecyclePolicy) Command(*exec.Cmd) error { return nil }
func (p *lifecyclePolicy) Sync() error             { return nil }

func (p *lifecyclePolicy) OnClose(stop func()) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return errors.New("policy is closed")
	}
	p.stops = append(p.stops, stop)
	return nil
}

func (p *lifecyclePolicy) Close() {
	p.mu.Lock()
	stops := p.stops
	p.stops = nil
	p.closed = true
	p.mu.Unlock()
	for _, stop := range stops {
		stop()
	}
}

func serverPoolWith(srv *managedServer) serverPool {
	return serverPool{servers: map[ProcessExecutionPolicy]*managedServer{nil: srv}}
}

func startSleepingServer(t *testing.T) *managedServer {
	t.Helper()
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("sh not available")
	}
	cmd := exec.Command(sh, "-c", "sleep 30")
	configureManagedServerCmd(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start server process: %v", err)
	}
	srv := &managedServer{cmd: cmd, exited: make(chan struct{})}
	go func() {
		srv.waitErr = cmd.Wait()
		close(srv.exited)
	}()
	return srv
}

func TestServerPoolBindsServerToItsPolicy(t *testing.T) {
	var pool serverPool
	defer pool.stopAll()
	started := 0
	start := func() (*managedServer, error) {
		started++
		return startSleepingServer(t), nil
	}
	lensA, lensB := &lifecyclePolicy{}, &lifecyclePolicy{}

	serverA, err := pool.ensure(lensA, start)
	if err != nil {
		t.Fatalf("start server for lens A: %v", err)
	}
	serverB, err := pool.ensure(lensB, start)
	if err != nil {
		t.Fatalf("start server for lens B: %v", err)
	}
	if serverA == serverB {
		t.Fatal("lens B was handed the server launched under lens A's policy")
	}
	if again, err := pool.ensure(lensA, start); err != nil || again != serverA {
		t.Fatalf("lens A did not reuse its own server: got %p err=%v, want %p", again, err, serverA)
	}
	if started != 2 {
		t.Fatalf("servers started = %d, want one per policy", started)
	}

	lensA.Close()
	select {
	case <-serverA.exited:
	default:
		t.Fatal("server outlived the policy it was launched under")
	}
	select {
	case <-serverB.exited:
		t.Fatal("closing lens A stopped lens B's server")
	default:
	}
	if _, err := pool.ensure(lensA, start); err == nil {
		t.Fatal("closed policy started a new server")
	}
}
