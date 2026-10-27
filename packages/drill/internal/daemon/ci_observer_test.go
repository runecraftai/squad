package daemon

import (
	"path/filepath"
	"testing"

	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

func TestPostGreenObservationWatchdogBudget(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "watchdog.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	repo, err := d.InsertRepo(t.TempDir(), "https://example.test/r.git", "main")
	if err != nil {
		t.Fatal(err)
	}
	run, err := d.InsertRun(repo.ID, "feature", "head", "base")
	if err != nil {
		t.Fatal(err)
	}
	if err = d.UpdateRunStatus(run.ID, types.RunRunning); err != nil {
		t.Fatal(err)
	}
	if err = d.UpdateRunPRURL(run.ID, "https://example.test/r/pull/1"); err != nil {
		t.Fatal(err)
	}
	if err = d.UpdateRunPushBinding(run.ID, db.PushBinding{HeadSHA: "head", TargetKind: "github", TargetFingerprint: "fingerprint", Ref: "refs/heads/feature"}); err != nil {
		t.Fatal(err)
	}
	in := db.PrepareCIObservationInput{RunID: run.ID, HeadSHA: "head", PushGeneration: 1, PushTargetFingerprint: "fingerprint", PushTargetKind: "github", PushRef: "refs/heads/feature", PRURL: "https://example.test/r/pull/1", FirstGreenAt: 100, DeadlineAt: 200}
	if err = d.PrepareCIObservation(in); err != nil {
		t.Fatal(err)
	}
	if err = d.ActivateCIObservation(run.ID, 1, "head", true, 110); err != nil {
		t.Fatal(err)
	}
	m := NewRunManager(d, nil, nil)
	m.scanCIObservationHealth(201)
	o, err := d.GetCIObservation(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if o.State != "expired" || o.Reason == nil || *o.Reason != "observation_budget_expired" {
		t.Fatalf("observation=%+v", o)
	}
	ns, err := d.ListCINotifications(run.ID)
	if err != nil || len(ns) != 1 || ns[0].Kind != "monitoring_failed" {
		t.Fatalf("notifications=%+v err=%v", ns, err)
	}
	r, err := d.GetRun(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if r.CIReadyAt != nil {
		t.Fatal("readiness remained set after expiry")
	}
}
