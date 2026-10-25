package executionpolicy

import (
	"os"
	"path/filepath"
	"testing"
)

func TestClosingPolicyStopsOwnersThenRemovesCopiedCredentials(t *testing.T) {
	host := t.TempDir()
	t.Setenv("HOME", host)
	credential := filepath.Join(host, ".claude", ".credentials.json")
	if err := os.MkdirAll(filepath.Dir(credential), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credential, []byte(`{"token":"host-token"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	p := &Policy{root: filepath.Join(t.TempDir(), "policy")}
	if err := os.Mkdir(p.root, 0o700); err != nil {
		t.Fatal(err)
	}
	launchHome, err := os.MkdirTemp(p.root, "launch-home-")
	if err != nil {
		t.Fatal(err)
	}
	if err := p.mountAgentCredentials("claude", launchHome); err != nil {
		t.Fatal(err)
	}
	copied := filepath.Join(launchHome, ".claude", ".credentials.json")
	if _, err := os.Stat(copied); err != nil {
		t.Fatalf("launch home lacks copied credential: %v", err)
	}

	ownerSawCredential := false
	if err := p.OnClose(func() {
		_, err := os.Stat(copied)
		ownerSawCredential = err == nil
	}); err != nil {
		t.Fatalf("register owner: %v", err)
	}
	if err := p.Close(); err != nil {
		t.Fatalf("close policy: %v", err)
	}
	if !ownerSawCredential {
		t.Fatal("owner stopped after copied credentials were already removed")
	}
	if _, err := os.Stat(copied); !os.IsNotExist(err) {
		t.Fatalf("copied credential survived policy close: %v", err)
	}
	if _, err := os.Stat(p.root); !os.IsNotExist(err) {
		t.Fatalf("policy root survived close: %v", err)
	}
	if err := p.OnClose(func() {}); err == nil {
		t.Fatal("closed policy accepted a new owner")
	}
}
