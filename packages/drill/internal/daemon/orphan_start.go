package daemon

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/runecraftai/squad/packages/drill/internal/branchsync"
	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
)

// HandleOrphanStart admits an audited local head, not the mutable gate branch
// tip. The accepted commit must be the released local head recorded at release
// or a proven descendant of it, so redoing the lost fixes after a release still
// has a supported fresh start. The prior run may have pushed successfully: its
// released record only qualifies while the lost head is the unpublished tail
// past the surviving published head. The private submission push only transfers
// objects; neither admission nor detached worktree creation updates either
// branch. Eligibility is checked again under the normal branch lock, before
// active runs could be cancelled.
func (m *RunManager) HandleOrphanStart(ctx context.Context, p *ipc.OrphanStartParams) (*ipc.OrphanStartResult, error) {
	repo, prior, err := m.validateOrphanStart(ctx, p)
	if err != nil {
		return nil, err
	}
	if p.CheckOnly {
		if err := m.clearStaleOrphanSubmission(ctx, repo, prior, p.HeadSHA); err != nil {
			return nil, err
		}
		return &ipc.OrphanStartResult{Ready: true}, nil
	}
	check := func() error {
		_, _, err := m.validateOrphanStart(ctx, p)
		return err
	}
	id, err := m.startRunChecked(ctx, repo, p.Branch, p.HeadSHA, prior.BaseSHA, "orphan_recovery", p.SkipSteps, p.Intent, db.RunIntentSourceAgent, p.SpecializedReview, check)
	if err != nil {
		return nil, fmt.Errorf("orphan_start_refused: %w", err)
	}
	return &ipc.OrphanStartResult{Ready: true, RunID: id}, nil
}

func (m *RunManager) validateOrphanStart(ctx context.Context, p *ipc.OrphanStartParams) (*db.Repo, *db.Run, error) {
	refuse := func(reason string) (*db.Repo, *db.Run, error) {
		return nil, nil, fmt.Errorf("orphan_start_refused: %s", reason)
	}
	prior, err := m.db.GetRun(p.PreviousRunID)
	if err != nil || prior == nil || prior.RepoID != p.RepoID || prior.Branch != p.Branch ||
		prior.CustodyReturnedAt == nil || prior.CustodyReturnNote == nil ||
		prior.CustodyReturnHead == nil || *prior.CustodyReturnHead == "" ||
		prior.PushActive || (prior.LastPushedSHA != nil && *prior.LastPushedSHA == prior.HeadSHA) ||
		(prior.Status != "failed" && prior.Status != "cancelled" && prior.Status != "completed") {
		return refuse("the requested commit is not a local head released from an orphaned run")
	}
	if strings.Trim(p.PreviousRunID, "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ") != "" {
		return refuse("invalid prior run identity")
	}
	if _, _, refusal, retired := branchsync.RetiredBranch(prior); retired {
		return refuse(refusal)
	}
	repo, err := m.db.GetRepo(p.RepoID)
	if err != nil || repo == nil {
		return refuse("repository registration is unavailable")
	}
	if err := m.validateOrphanBranchOwnership(repo.ID, p.Branch, prior); err != nil {
		return refuse(err.Error())
	}
	gateDir := m.paths.RepoDir(repo.ID)
	if err := git.ValidateBareRepository(ctx, gateDir); err != nil {
		return refuse("the registered gate is unavailable")
	}
	missing, err := git.ObjectMissing(ctx, gateDir, prior.HeadSHA)
	if err != nil || !missing {
		return refuse("the recorded pipeline head is not proven missing")
	}
	if _, err := git.Run(ctx, gateDir, "check-ref-format", "refs/heads/"+p.Branch); err != nil {
		return refuse("invalid branch identity")
	}
	// The preflight runs before the CLI's non-forced private push, so the exact
	// requested commit cannot be in the gate yet. The authoritative start below
	// proves the exact submitted head and its descent under the branch lock.
	if p.CheckOnly {
		return repo, prior, nil
	}
	ref := ipc.OrphanSubmissionPrefix + prior.ID
	staged, stageErr := git.Run(ctx, gateDir, "rev-parse", "--verify", ref+"^{commit}")
	if stageErr != nil || staged != p.HeadSHA {
		return refuse("the exact local commit was not submitted to the private ref")
	}
	// The released head stays the immutable audit anchor. A later local head is
	// admitted only when the submitted commit proves it descends from that
	// anchor, so a rewritten or unrelated head still refuses.
	if audited := *prior.CustodyReturnHead; p.HeadSHA != audited && !git.IsAncestor(ctx, gateDir, audited, p.HeadSHA) {
		return refuse("the requested commit does not descend from the audited released local head")
	}
	return repo, prior, nil
}

// validateOrphanBranchOwnership proves no run currently owns the branch and
// that the released orphan is still its newest run, so a stale submission can
// never be cleared while a live or successor run depends on it.
func (m *RunManager) validateOrphanBranchOwnership(repoID, branch string, prior *db.Run) error {
	runs, err := m.db.GetRunsByRepo(repoID)
	if err != nil {
		return errors.New("cannot verify current branch ownership")
	}
	latest := ""
	for _, run := range runs {
		if run.Branch != branch {
			continue
		}
		if latest == "" {
			latest = run.ID
		}
		if run.Status == "pending" || run.Status == "running" || run.PushActive {
			return errors.New("a live run already owns this branch")
		}
	}
	if latest != prior.ID {
		return errors.New("a newer run already owns this branch")
	}
	return nil
}

// clearStaleOrphanSubmission removes a private submission left behind by a
// failed start so the next non-forced push can create it again, including when
// it cannot fast-forward the leftover ref. It holds the branch lock, re-proves
// that no live run owns the branch, and deletes only the exact commit it
// observed, so a concurrent submission is never clobbered.
func (m *RunManager) clearStaleOrphanSubmission(ctx context.Context, repo *db.Repo, prior *db.Run, head string) error {
	ref := ipc.OrphanSubmissionPrefix + prior.ID
	gateDir := m.paths.RepoDir(repo.ID)
	branchMu := m.branchLock(repo.ID, prior.Branch)
	branchMu.Lock()
	defer branchMu.Unlock()
	staged, err := git.Run(ctx, gateDir, "rev-parse", "--verify", ref+"^{commit}")
	if err != nil || staged == head {
		return nil
	}
	if err := m.validateOrphanBranchOwnership(repo.ID, prior.Branch, prior); err != nil {
		return fmt.Errorf("orphan_start_refused: %s", err)
	}
	if _, err := git.Run(ctx, gateDir, "update-ref", "-d", ref, staged); err != nil {
		return fmt.Errorf("orphan_start_refused: the stale private submission could not be cleared; no branch push attempted: %w", err)
	}
	return nil
}
