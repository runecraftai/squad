package daemon

import (
	"context"
	"fmt"
	"strings"

	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
)

// HandleOrphanStart admits an audited local head, not the mutable gate branch
// tip. The private submission push only transfers objects; neither admission
// nor detached worktree creation updates either branch. Eligibility is checked
// again under the normal branch lock, before active runs could be cancelled.
func (m *RunManager) HandleOrphanStart(ctx context.Context, p *ipc.OrphanStartParams) (*ipc.OrphanStartResult, error) {
	repo, prior, err := m.validateOrphanStart(ctx, p)
	if err != nil {
		return nil, err
	}
	if p.CheckOnly {
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
		prior.CustodyReturnHead == nil || *prior.CustodyReturnHead != p.HeadSHA ||
		prior.LastPushedSHA != nil || prior.PushActive ||
		(prior.Status != "failed" && prior.Status != "cancelled" && prior.Status != "completed") {
		return refuse("the requested commit is not the audited local head of a released orphan")
	}
	if strings.Trim(p.PreviousRunID, "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ") != "" {
		return refuse("invalid prior run identity")
	}
	repo, err := m.db.GetRepo(p.RepoID)
	if err != nil || repo == nil {
		return refuse("repository registration is unavailable")
	}
	runs, err := m.db.GetRunsByRepo(repo.ID)
	if err != nil {
		return refuse("cannot verify current branch ownership")
	}
	latest := ""
	for _, run := range runs {
		if run.Branch != p.Branch {
			continue
		}
		if latest == "" {
			latest = run.ID
		}
		if run.Status == "pending" || run.Status == "running" || run.PushActive {
			return refuse("a live run already owns this branch")
		}
	}
	if latest != prior.ID {
		return refuse("a newer run already owns this branch")
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
	ref := ipc.OrphanSubmissionPrefix + prior.ID
	staged, stageErr := git.Run(ctx, gateDir, "rev-parse", "--verify", ref+"^{commit}")
	if stageErr == nil && staged != p.HeadSHA {
		return refuse("the private submission names a different commit")
	}
	if !p.CheckOnly && (stageErr != nil || staged != p.HeadSHA) {
		return refuse("the exact local commit was not submitted to the private ref")
	}
	return repo, prior, nil
}
