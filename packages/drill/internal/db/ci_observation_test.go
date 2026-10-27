package db

import (
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/types"
)

func observationFixture(t *testing.T) (*DB, *Run, PrepareCIObservationInput) {
	t.Helper()
	d := openTestDB(t)
	repo, err := d.InsertRepo("/tmp/ci-observation", "https://example.test/repo.git", "main")
	if err != nil {
		t.Fatal(err)
	}
	run, err := d.InsertRun(repo.ID, "feature", "abc123", "base")
	if err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateRunStatus(run.ID, types.RunRunning); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateRunPRURL(run.ID, "https://example.test/repo/pull/7"); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateRunPushBinding(run.ID, PushBinding{HeadSHA: "abc123", TargetKind: "github", TargetFingerprint: "target-hash", Ref: "refs/heads/feature"}); err != nil {
		t.Fatal(err)
	}
	return d, run, PrepareCIObservationInput{RunID: run.ID, HeadSHA: "abc123", PushGeneration: 1, PushTargetFingerprint: "target-hash", PushTargetKind: "github", PushRef: "refs/heads/feature", PRURL: "https://example.test/repo/pull/7", FirstGreenAt: 100, DeadlineAt: 200}
}

func TestPostGreenPrepareAndActivateAtomic(t *testing.T) {
	d, run, in := observationFixture(t)
	if err := d.PrepareCIObservation(in); err != nil {
		t.Fatal(err)
	}
	if err := d.PrepareCIObservation(in); err != nil {
		t.Fatalf("idempotent prepare: %v", err)
	}
	bad := in
	bad.PushGeneration++
	if err := d.PrepareCIObservation(bad); err == nil {
		t.Fatal("mismatched generation was accepted")
	}
	o, err := d.GetCIObservation(run.ID)
	if err != nil || o == nil || o.State != "preparing" {
		t.Fatalf("observation = %#v, err %v", o, err)
	}
	if err := d.ActivateCIObservation(run.ID, 1, "abc123", false, 110); err == nil {
		t.Fatal("activated without verified quiescence")
	}
	if err := d.ActivateCIObservation(run.ID, 1, "abc123", true, 110); err != nil {
		t.Fatal(err)
	}
	r, err := d.GetRun(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != types.RunCompleted || r.CIReadyAt == nil || *r.CIReadyAt != 110 || r.PushActive || r.AwaitingAgentSince != nil {
		t.Fatalf("run not atomically completed: %#v", r)
	}
	o, err = d.GetCIObservation(run.ID)
	if err != nil || o.State != "watching" {
		t.Fatalf("observation = %#v, err %v", o, err)
	}
}

func TestPostGreenLeaseCAS(t *testing.T) {
	d, run, in := observationFixture(t)
	if err := d.PrepareCIObservation(in); err != nil {
		t.Fatal(err)
	}
	if err := d.ActivateCIObservation(run.ID, 1, "abc123", true, 110); err != nil {
		t.Fatal(err)
	}
	o, ok, err := d.AcquireCIObservationLease(run.ID, 110, 130)
	if err != nil || !ok {
		t.Fatalf("lease=%v err=%v", ok, err)
	}
	if o.PollSeq != 1 || o.LeaseUntil == nil || *o.LeaseUntil != 130 {
		t.Fatalf("lease state=%+v", o)
	}
	committed, err := d.CommitCIObservationSample(CIObservationSample{RunID: run.ID, PollSeq: 0, PushGeneration: 1, At: 111, NextPollAt: 120, Verdict: "red", State: "watching"})
	if err != nil {
		t.Fatal(err)
	}
	if committed {
		t.Fatal("stale token committed")
	}
	committed, err = d.CommitCIObservationSample(CIObservationSample{RunID: run.ID, PollSeq: 1, PushGeneration: 1, At: 111, NextPollAt: 120, Verdict: "red", State: "watching"})
	if err != nil {
		t.Fatal(err)
	}
	if !committed {
		t.Fatal("current token did not commit")
	}
}

func TestPostGreenPRRetirementMonotonic(t *testing.T) {
	d, run, in := observationFixture(t)
	if err := d.PrepareCIObservation(in); err != nil {
		t.Fatal(err)
	}
	if err := d.ActivateCIObservation(run.ID, 1, "abc123", true, 110); err != nil {
		t.Fatal(err)
	}
	n := &CINotification{RunID: run.ID, Kind: "regression", HeadSHA: "abc123", PRURL: in.PRURL, Summary: "late failure", DetailsJSON: "{}", CreatedAt: 120}
	if ok, err := d.CommitCIObservationSample(CIObservationSample{RunID: run.ID, PollSeq: 0, PushGeneration: 1, At: 120, NextPollAt: 130, Verdict: "red", State: "watching", Notification: n}); err != nil || !ok {
		t.Fatalf("sample: ok=%v err=%v", ok, err)
	}
	if err := d.UpdateRunPRState(run.ID, "merged"); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateRunPRState(run.ID, "open"); err != nil {
		t.Fatal(err)
	}
	o, err := d.GetCIObservation(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if o.State != "merged" {
		t.Fatalf("state resurrected: %q", o.State)
	}
	notifications, err := d.ListCINotifications(run.ID)
	if err != nil || len(notifications) != 1 {
		t.Fatalf("notifications=%d err=%v", len(notifications), err)
	}
}

func TestPostGreenNotificationExactlyOnce(t *testing.T) {
	d, run, in := observationFixture(t)
	if err := d.PrepareCIObservation(in); err != nil {
		t.Fatal(err)
	}
	if err := d.ActivateCIObservation(run.ID, 1, "abc123", true, 110); err != nil {
		t.Fatal(err)
	}
	n := &CINotification{RunID: run.ID, Kind: "regression", HeadSHA: "abc123", PRURL: in.PRURL, Summary: "check failed", DetailsJSON: "{}", CreatedAt: 120}
	ok, err := d.CommitCIObservationSample(CIObservationSample{RunID: run.ID, PollSeq: 0, PushGeneration: 1, At: 120, NextPollAt: 130, Verdict: "red", State: "watching", ConsecutiveErrors: 0, Notification: n})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("matching sample token was rejected")
	}
	ok, err = d.CommitCIObservationSample(CIObservationSample{RunID: run.ID, PollSeq: 0, PushGeneration: 1, At: 121, NextPollAt: 130, Verdict: "red", State: "watching", ConsecutiveErrors: 0, Notification: n})
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("duplicate poll token was accepted")
	}
	got, err := d.ListCINotifications(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("notifications=%d, want one", len(got))
	}
	obs, err := d.GetCIObservation(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if obs.FirstGreenAt != 100 {
		t.Fatalf("first-green changed: %d", obs.FirstGreenAt)
	}
}
