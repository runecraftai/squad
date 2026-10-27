package cimonitor

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/scm"
)

// Reader intentionally exposes only provider reads needed by post-green
// observation; it cannot create, update, merge, or rerun a PR.
type Reader interface {
	Available(context.Context) error
	Capabilities() scm.Capabilities
	GetPRState(context.Context, *scm.PR) (scm.PRState, error)
	GetPRHeadSHA(context.Context, *scm.PR) (string, error)
	GetChecks(context.Context, *scm.PR) ([]scm.Check, error)
	GetMergeableState(context.Context, *scm.PR) (scm.MergeableState, error)
}

type ObservationCandidate struct {
	HeadSHA      string
	PR           *scm.PR
	DeclaredNoCI bool
}

type Sample struct {
	At                                   time.Time
	HeadBefore, HeadAfter, PublishedHead string
	PRState                              scm.PRState
	Mergeable                            scm.MergeableState
	Checks                               []scm.Check
	Verdict                              string
	Reason                               string
}

// PublishedHead reads the exact configured remote ref without fetching or
// mutating local refs. The caller must bind it to the stored push target.
type PublishedHead func(context.Context) (string, error)

// SampleBound takes all required reads under one deadline and accepts green
// only for a stable, exactly-bound candidate head.
func SampleBound(ctx context.Context, reader Reader, pr *scm.PR, candidate ObservationCandidate, published PublishedHead, timeout time.Duration, now func() time.Time) (Sample, error) {
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	if now == nil {
		now = time.Now
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	s := Sample{At: now(), Verdict: "unknown"}
	if err := reader.Available(ctx); err != nil {
		return s, fmt.Errorf("observation provider unavailable: %w", err)
	}
	state, err := reader.GetPRState(ctx, pr)
	if err != nil {
		return s, fmt.Errorf("read PR state: %w", err)
	}
	s.PRState = state
	before, err := reader.GetPRHeadSHA(ctx, pr)
	if err != nil {
		return s, fmt.Errorf("read PR head before checks: %w", err)
	}
	s.HeadBefore = strings.TrimSpace(before)
	if !reader.Capabilities().MergeableState {
		return s, fmt.Errorf("provider cannot positively resolve PR mergeability")
	}
	mergeable, err := reader.GetMergeableState(ctx, pr)
	if err != nil {
		return s, fmt.Errorf("read PR mergeability: %w", err)
	}
	s.Mergeable = mergeable
	checks, err := reader.GetChecks(ctx, pr)
	if err != nil {
		return s, fmt.Errorf("read PR checks: %w", err)
	}
	s.Checks = checks
	after, err := reader.GetPRHeadSHA(ctx, pr)
	if err != nil {
		return s, fmt.Errorf("read PR head after checks: %w", err)
	}
	s.HeadAfter = strings.TrimSpace(after)
	if published == nil {
		return s, fmt.Errorf("published-head reader is unavailable")
	}
	remote, err := published(ctx)
	if err != nil {
		return s, fmt.Errorf("read published PR head: %w", err)
	}
	s.PublishedHead = strings.TrimSpace(remote)
	if s.HeadBefore != candidate.HeadSHA || s.HeadAfter != candidate.HeadSHA || s.PublishedHead != candidate.HeadSHA {
		s.Reason = "PR or published head differs from observation candidate"
		return s, nil
	}
	if state != scm.PRStateOpen {
		s.Reason = "PR is not open"
		return s, nil
	}
	if mergeable == scm.MergeableConflict {
		s.Verdict = "red"
		s.Reason = "PR has merge conflicts"
		return s, nil
	}
	if mergeable != scm.MergeableOK {
		s.Reason = "PR mergeability is unresolved"
		return s, nil
	}
	if len(checks) == 0 {
		if candidate.DeclaredNoCI {
			s.Verdict = "green"
			return s, nil
		}
		s.Reason = "provider reported no checks without trusted no-CI policy"
		return s, nil
	}
	passed := false
	pending := false
	for _, check := range checks {
		switch check.Bucket {
		case scm.CheckBucketFail, scm.CheckBucketCancel:
			s.Verdict = "red"
			s.Reason = "one or more CI checks failed or were cancelled"
			return s, nil
		case scm.CheckBucketPass, scm.CheckBucketSkip:
			passed = true
		case scm.CheckBucketPending:
			pending = true
		default:
			s.Reason = "provider returned an unknown CI check state"
			return s, nil
		}
	}
	if pending {
		s.Verdict = "pending"
		return s, nil
	}
	if passed {
		s.Verdict = "green"
		return s, nil
	}
	s.Reason = "provider returned no classifiable CI checks"
	return s, nil
}
