package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolvePoolDir_EmptyRoot(t *testing.T) {
	// With empty root, pool dir should be under $HOME/.fob/{repoName}-{hash}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}

	// We need a real repo for GetRemoteURL. Use a fake approach by creating
	// a temp git repo with a remote.
	repoDir := setupGitRepo(t)

	poolDir, err := ResolvePoolDir(repoDir, "")
	if err != nil {
		t.Fatalf("ResolvePoolDir failed: %v", err)
	}

	repoName := filepath.Base(repoDir)
	if !strings.HasPrefix(poolDir, filepath.Join(home, ".fob", repoName)) {
		t.Errorf("expected pool dir under %s/.fob/%s-*, got %s", home, repoName, poolDir)
	}
}

func TestResolvePoolDir_RelativeRoot(t *testing.T) {
	repoDir := setupGitRepo(t)

	poolDir, err := ResolvePoolDir(repoDir, ".worktrees")
	if err != nil {
		t.Fatalf("ResolvePoolDir failed: %v", err)
	}

	repoName := filepath.Base(repoDir)
	expected := filepath.Join(repoDir, ".worktrees", ".fob", repoName)
	if !strings.HasPrefix(poolDir, expected) {
		t.Errorf("expected pool dir to start with %s, got %s", expected, poolDir)
	}
}

func TestResolvePoolDir_AbsoluteRoot(t *testing.T) {
	repoDir := setupGitRepo(t)
	absRoot := t.TempDir()

	poolDir, err := ResolvePoolDir(repoDir, absRoot)
	if err != nil {
		t.Fatalf("ResolvePoolDir failed: %v", err)
	}

	repoName := filepath.Base(repoDir)
	expected := filepath.Join(absRoot, ".fob", repoName)
	if !strings.HasPrefix(poolDir, expected) {
		t.Errorf("expected pool dir to start with %s, got %s", expected, poolDir)
	}
}

func TestResolvePoolDir_DotSlashRoot(t *testing.T) {
	repoDir := setupGitRepo(t)

	poolDir, err := ResolvePoolDir(repoDir, "./")
	if err != nil {
		t.Fatalf("ResolvePoolDir failed: %v", err)
	}

	repoName := filepath.Base(repoDir)
	expected := filepath.Join(repoDir, ".fob", repoName)
	if !strings.HasPrefix(poolDir, expected) {
		t.Errorf("expected pool dir to start with %s, got %s", expected, poolDir)
	}
}

func TestResolvePoolDir_EnvVarExpansion(t *testing.T) {
	repoDir := setupGitRepo(t)
	absRoot := t.TempDir()

	t.Setenv("TEST_FOB_ROOT", absRoot)

	poolDir, err := ResolvePoolDir(repoDir, "$TEST_FOB_ROOT")
	if err != nil {
		t.Fatalf("ResolvePoolDir failed: %v", err)
	}

	repoName := filepath.Base(repoDir)
	expected := filepath.Join(absRoot, ".fob", repoName)
	if !strings.HasPrefix(poolDir, expected) {
		t.Errorf("expected pool dir to start with %s, got %s", expected, poolDir)
	}
}

func TestResolvePoolRoot_EmptyRoot(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}

	poolRoot, err := ResolvePoolRoot("", "")
	if err != nil {
		t.Fatalf("ResolvePoolRoot failed: %v", err)
	}

	expected := filepath.Join(home, ".fob")
	if poolRoot != expected {
		t.Fatalf("expected pool root %s, got %s", expected, poolRoot)
	}
}

func TestResolvePoolRoot_RelativeRootRequiresRepo(t *testing.T) {
	if _, err := ResolvePoolRoot("", ".worktrees"); err == nil {
		t.Fatal("expected relative root without repo to fail")
	}
}
