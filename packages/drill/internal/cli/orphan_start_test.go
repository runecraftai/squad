package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
)

// Real Git plus a protocol stub pins CLI admission order and refusal without
// fallback. The daemon integration tests exercise actual successor creation.
func TestTriggerOrphanRunPrivateSubmissionAndNoFallback(t *testing.T) {
	for _, mode := range []string{"supported", "unsupported", "refused", "start refused"} {
		t.Run(mode, func(t *testing.T) {
			f := newCLIRecoverFixture(t)
			p, err := paths.New()
			if err != nil {
				t.Fatal(err)
			}
			database, err := db.Open(p.DB())
			if err != nil {
				t.Fatal(err)
			}
			defer database.Close()
			repo, err := database.GetRepoByPath(f.local)
			if err != nil || repo == nil {
				t.Fatalf("repo: %#v, %v", repo, err)
			}
			runs, err := database.GetRunsByRepo(repo.ID)
			if err != nil || len(runs) != 1 {
				t.Fatalf("runs: %#v, %v", runs, err)
			}
			prior := runs[0]
			missing := strings.Repeat("a", 40)
			if err := database.UpdateRunHeadSHA(prior.ID, missing); err != nil {
				t.Fatal(err)
			}
			if err := database.ReleaseOrphanedRun(prior.ID, missing, f.submitted); err != nil {
				t.Fatal(err)
			}
			srv := ipc.NewServer()
			if mode != "unsupported" {
				srv.Handle(ipc.MethodStartOrphan, func(ctx context.Context, raw json.RawMessage) (interface{}, error) {
					var request ipc.OrphanStartParams
					if err := json.Unmarshal(raw, &request); err != nil {
						return nil, err
					}
					if mode == "refused" || (mode == "start refused" && !request.CheckOnly) {
						return nil, fmt.Errorf("orphan_start_refused: cannot prove exact-head admission")
					}
					if request.HeadSHA != f.submitted || request.PreviousRunID != prior.ID || request.Intent != "full accepted intent" {
						return nil, fmt.Errorf("wrong submission identity or intent")
					}
					if request.CheckOnly {
						return &ipc.OrphanStartResult{Ready: true}, nil
					}
					staged, err := git.Run(ctx, f.gate, "rev-parse", ipc.OrphanSubmissionPrefix+prior.ID+"^{commit}")
					if err != nil || staged != f.submitted {
						return nil, fmt.Errorf("exact local commit was not pushed")
					}
					return &ipc.OrphanStartResult{Ready: true, RunID: "successor"}, nil
				})
			}
			socket := filepath.Join(makeSocketSafeTempDir(t), "orphan.sock")
			errCh := make(chan error, 1)
			go func() { errCh <- srv.Serve(socket) }()
			t.Cleanup(func() { srv.Close(); <-errCh })
			var client *ipc.Client
			deadline := time.Now().Add(time.Second)
			for time.Now().Before(deadline) {
				client, err = ipc.Dial(socket)
				if err == nil {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			if client == nil {
				t.Fatal("test IPC server did not start")
			}
			defer client.Close()
			env := &axiEnv{d: database, repo: repo, p: p, client: client}
			localBefore := cliGit(t, f.local, "show-ref")
			gateBefore := cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover")
			id, err := triggerRun(context.Background(), env, "feature/recover", f.submitted, nil, "full accepted intent", false)
			if mode == "supported" {
				if err != nil || id != "successor" {
					t.Fatalf("exact-head submission: %s, %v", id, err)
				}
			} else if err == nil || !strings.Contains(err.Error(), "orphan_start_") || id != "" {
				t.Fatalf("expected named refusal: %s, %v", id, err)
			}
			if cliGit(t, f.local, "show-ref") != localBefore || cliGit(t, f.gate, "rev-parse", "refs/heads/feature/recover") != gateBefore {
				t.Fatal("submission or refusal moved a branch")
			}
			_, stagedErr := git.Run(context.Background(), f.gate, "rev-parse", "--verify", ipc.OrphanSubmissionPrefix+prior.ID+"^{commit}")
			if (mode == "unsupported" || mode == "refused") && stagedErr == nil {
				t.Fatal("CLI pushed before daemon admitted exact-head support")
			}
		})
	}
}
