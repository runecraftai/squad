package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
)

// CIObservation is the immutable identity and mutable polling state for one
// post-green read-only observation.
type CIObservation struct {
	RunID                 string  `json:"run_id"`
	HeadSHA               string  `json:"head_sha"`
	PushGeneration        int64   `json:"push_generation"`
	PushTargetFingerprint string  `json:"push_target_fingerprint"`
	PushTargetKind        string  `json:"push_target_kind"`
	PushRef               string  `json:"push_ref"`
	PRURL                 string  `json:"pr_url"`
	DeclaredNoCI          bool    `json:"declared_no_ci"`
	FirstGreenAt          int64   `json:"first_green_at"`
	DeadlineAt            int64   `json:"deadline_at"`
	State                 string  `json:"state"`
	Verdict               string  `json:"verdict"`
	LastPollAt            *int64  `json:"last_poll_at"`
	NextPollAt            int64   `json:"next_poll_at"`
	LeaseUntil            *int64  `json:"lease_until"`
	PollSeq               int64   `json:"poll_seq"`
	ConsecutiveErrors     int64   `json:"consecutive_errors"`
	Reason                *string `json:"reason"`
	UpdatedAt             int64   `json:"updated_at"`
}

// CINotification is a durable, deduplicated post-green notification.
type CINotification struct {
	RunID       string `json:"run_id"`
	Kind        string `json:"kind"`
	HeadSHA     string `json:"head_sha"`
	PRURL       string `json:"pr_url"`
	Summary     string `json:"summary"`
	DetailsJSON string `json:"details_json"`
	CreatedAt   int64  `json:"created_at"`
}

type PrepareCIObservationInput struct {
	RunID, HeadSHA                                        string
	PushGeneration                                        int64
	PushTargetFingerprint, PushTargetKind, PushRef, PRURL string
	DeclaredNoCI                                          bool
	FirstGreenAt, DeadlineAt                              int64
}

// PrepareCIObservation durably reserves a successful, exact published head.
// Repeating the same identity is idempotent; changing any pinned field is refused.
func (d *DB) PrepareCIObservation(in PrepareCIObservationInput) error {
	tx, err := d.sql.Begin()
	if err != nil {
		return fmt.Errorf("prepare CI observation: begin: %w", err)
	}
	defer tx.Rollback()
	var gen sql.NullInt64
	var sha, fingerprint, kind, ref, pr string
	var active int
	var status string
	err = tx.QueryRow(`SELECT status, last_pushed_sha, push_generation, push_target_fingerprint, push_target_kind, push_ref, pr_url, push_active FROM runs WHERE id = ?`, in.RunID).Scan(&status, &sha, &gen, &fingerprint, &kind, &ref, &pr, &active)
	if err != nil {
		return fmt.Errorf("prepare CI observation: read run: %w", err)
	}
	if status != "running" || active != 0 || !gen.Valid || gen.Int64 != in.PushGeneration || sha != in.HeadSHA || fingerprint != in.PushTargetFingerprint || kind != in.PushTargetKind || ref != in.PushRef || pr != in.PRURL || in.HeadSHA == "" || in.PRURL == "" {
		return fmt.Errorf("prepare CI observation: run is not bound to the requested successful push")
	}
	var old CIObservation
	err = scanCIObservation(tx.QueryRow(`SELECT `+ciObservationColumns+` FROM ci_observations WHERE run_id = ?`, in.RunID), &old)
	if err == nil {
		if sameCIObservationIdentity(&old, in) {
			return tx.Commit()
		}
		return fmt.Errorf("prepare CI observation: mismatching observation already exists")
	}
	if err != sql.ErrNoRows {
		return fmt.Errorf("prepare CI observation: read existing observation: %w", err)
	}
	ts := now()
	_, err = tx.Exec(`INSERT INTO ci_observations (run_id, head_sha, push_generation, push_target_fingerprint, push_target_kind, push_ref, pr_url, declared_no_ci, first_green_at, deadline_at, state, verdict, next_poll_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'preparing', 'green', ?, ?)`, in.RunID, in.HeadSHA, in.PushGeneration, in.PushTargetFingerprint, in.PushTargetKind, in.PushRef, in.PRURL, in.DeclaredNoCI, in.FirstGreenAt, in.DeadlineAt, in.FirstGreenAt, ts)
	if err != nil {
		return fmt.Errorf("prepare CI observation: insert: %w", err)
	}
	return tx.Commit()
}

// ActivateCIObservation makes execution completion and observation activation atomic.
func (d *DB) ActivateCIObservation(runID string, generation int64, finalHead string, quiescent bool, at int64) error {
	if !quiescent {
		return fmt.Errorf("activate CI observation: execution is not verified quiescent")
	}
	tx, err := d.sql.Begin()
	if err != nil {
		return fmt.Errorf("activate CI observation: begin: %w", err)
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE ci_observations SET state='watching', verdict='green', next_poll_at=?, updated_at=? WHERE run_id=? AND state='preparing' AND push_generation=? AND head_sha=?`, at, at, runID, generation, finalHead)
	if err != nil {
		return fmt.Errorf("activate CI observation: activate: %w", err)
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return fmt.Errorf("activate CI observation: preparation identity changed")
	}
	res, err = tx.Exec(`UPDATE runs SET status='completed', ci_ready_at=?, terminal_head_verified_at=?, push_active=0, awaiting_agent_since=NULL, head_sha=?, updated_at=? WHERE id=? AND status='running' AND push_generation=? AND last_pushed_sha=?`, at, at, finalHead, at, runID, generation, finalHead)
	if err != nil {
		return fmt.Errorf("activate CI observation: complete run: %w", err)
	}
	n, _ = res.RowsAffected()
	if n != 1 {
		return fmt.Errorf("activate CI observation: run identity changed")
	}
	if _, err := tx.Exec(`UPDATE step_results SET status='completed', completed_at=? WHERE run_id=? AND step_name='ci' AND status IN ('running','pending')`, at, runID); err != nil {
		return fmt.Errorf("activate CI observation: complete CI step: %w", err)
	}
	return tx.Commit()
}

func (d *DB) GetCIObservation(runID string) (*CIObservation, error) {
	var o CIObservation
	err := scanCIObservation(d.sql.QueryRow(`SELECT `+ciObservationColumns+` FROM ci_observations WHERE run_id=?`, runID), &o)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get CI observation: %w", err)
	}
	return &o, nil
}

func (d *DB) ListWatchingCIObservations() ([]*CIObservation, error) {
	rows, err := d.sql.Query(`SELECT ` + ciObservationColumns + ` FROM ci_observations WHERE state='watching' ORDER BY next_poll_at, run_id`)
	if err != nil {
		return nil, fmt.Errorf("list watching CI observations: %w", err)
	}
	defer rows.Close()
	var out []*CIObservation
	for rows.Next() {
		var o CIObservation
		if err := scanCIObservation(rows, &o); err != nil {
			return nil, err
		}
		out = append(out, &o)
	}
	return out, rows.Err()
}

// AcquireCIObservationLease advances the poll token before provider reads. A
// stale watcher cannot commit after another worker has claimed a newer lease.
func (d *DB) AcquireCIObservationLease(runID string, at, leaseUntil int64) (*CIObservation, bool, error) {
	res, err := d.sql.Exec(`UPDATE ci_observations SET poll_seq=poll_seq+1, lease_until=?, updated_at=? WHERE run_id=? AND state='watching' AND next_poll_at<=? AND (lease_until IS NULL OR lease_until<=?)`, leaseUntil, at, runID, at, at)
	if err != nil {
		return nil, false, fmt.Errorf("acquire CI observation lease: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return nil, false, err
	}
	if n == 0 {
		return nil, false, nil
	}
	o, err := d.GetCIObservation(runID)
	if err != nil {
		return nil, false, err
	}
	return o, o != nil, nil
}

type CIObservationSample struct {
	RunID                   string
	PollSeq, PushGeneration int64
	At, NextPollAt          int64
	Verdict, State          string
	ConsecutiveErrors       int64
	Reason                  *string
	Notification            *CINotification
}

// CommitCIObservationSample is a lease-token CAS. Notification creation and the
// sample update share one transaction, so failed writes cannot acknowledge a poll.
func (d *DB) CommitCIObservationSample(s CIObservationSample) (bool, error) {
	tx, err := d.sql.Begin()
	if err != nil {
		return false, fmt.Errorf("commit CI observation sample: begin: %w", err)
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE ci_observations SET verdict=?, state=?, last_poll_at=?, next_poll_at=?, lease_until=NULL, poll_seq=poll_seq+1, consecutive_errors=?, reason=?, updated_at=? WHERE run_id=? AND state='watching' AND poll_seq=? AND push_generation=? AND NOT EXISTS (SELECT 1 FROM runs active WHERE active.repo_id=(SELECT repo_id FROM runs WHERE id=?) AND active.branch=(SELECT branch FROM runs WHERE id=?) AND active.id!=? AND active.status IN ('pending','running'))`, s.Verdict, s.State, s.At, s.NextPollAt, s.ConsecutiveErrors, s.Reason, s.At, s.RunID, s.PollSeq, s.PushGeneration, s.RunID, s.RunID, s.RunID)
	if err != nil {
		return false, fmt.Errorf("commit CI observation sample: update: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	if n != 1 {
		return false, nil
	}
	if s.Notification != nil {
		n := s.Notification
		if _, err := tx.Exec(`INSERT INTO ci_notifications (run_id,kind,head_sha,pr_url,summary,details_json,created_at) VALUES (?,?,?,?,?,?,?) ON CONFLICT(run_id,kind) DO NOTHING`, n.RunID, n.Kind, n.HeadSHA, n.PRURL, n.Summary, n.DetailsJSON, n.CreatedAt); err != nil {
			return false, fmt.Errorf("commit CI observation sample: notification: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("commit CI observation sample: commit: %w", err)
	}
	return true, nil
}

func (d *DB) FailCIObservation(runID string, generation int64, state, reason string, at int64, notification *CINotification) error {
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE ci_observations SET state=?, verdict='unknown', reason=?, lease_until=NULL, updated_at=? WHERE run_id=? AND push_generation=? AND state IN ('preparing','watching')`, state, reason, at, runID, generation)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("fail CI observation: identity changed")
	}
	if _, err := tx.Exec(`UPDATE runs SET ci_ready_at=NULL, ci_ready_no_ci=0, updated_at=? WHERE id=?`, at, runID); err != nil {
		return err
	}
	if notification != nil {
		x := notification
		if _, err := tx.Exec(`INSERT INTO ci_notifications (run_id,kind,head_sha,pr_url,summary,details_json,created_at) VALUES (?,?,?,?,?,?,?) ON CONFLICT(run_id,kind) DO NOTHING`, x.RunID, x.Kind, x.HeadSHA, x.PRURL, x.Summary, x.DetailsJSON, x.CreatedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (d *DB) ListCINotifications(runID string) ([]CINotification, error) {
	rows, err := d.sql.Query(`SELECT run_id,kind,head_sha,pr_url,summary,details_json,created_at FROM ci_notifications WHERE run_id=? ORDER BY created_at,kind`, runID)
	if err != nil {
		return nil, fmt.Errorf("list CI notifications: %w", err)
	}
	defer rows.Close()
	var out []CINotification
	for rows.Next() {
		var n CINotification
		if err := rows.Scan(&n.RunID, &n.Kind, &n.HeadSHA, &n.PRURL, &n.Summary, &n.DetailsJSON, &n.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

const ciObservationColumns = `run_id,head_sha,push_generation,push_target_fingerprint,push_target_kind,push_ref,pr_url,declared_no_ci,first_green_at,deadline_at,state,verdict,last_poll_at,next_poll_at,lease_until,poll_seq,consecutive_errors,reason,updated_at`

func scanCIObservation(row interface{ Scan(...any) error }, o *CIObservation) error {
	return row.Scan(&o.RunID, &o.HeadSHA, &o.PushGeneration, &o.PushTargetFingerprint, &o.PushTargetKind, &o.PushRef, &o.PRURL, &o.DeclaredNoCI, &o.FirstGreenAt, &o.DeadlineAt, &o.State, &o.Verdict, &o.LastPollAt, &o.NextPollAt, &o.LeaseUntil, &o.PollSeq, &o.ConsecutiveErrors, &o.Reason, &o.UpdatedAt)
}
func sameCIObservationIdentity(o *CIObservation, in PrepareCIObservationInput) bool {
	return o.HeadSHA == in.HeadSHA && o.PushGeneration == in.PushGeneration && o.PushTargetFingerprint == in.PushTargetFingerprint && o.PushTargetKind == in.PushTargetKind && o.PushRef == in.PushRef && o.PRURL == in.PRURL && o.DeclaredNoCI == in.DeclaredNoCI && o.FirstGreenAt == in.FirstGreenAt && o.DeadlineAt == in.DeadlineAt
}

// DetailsJSON encodes sanitized observer details supplied by the caller.
func (n *CINotification) SetDetails(value any) error {
	b, err := json.Marshal(value)
	if err != nil {
		return err
	}
	n.DetailsJSON = string(b)
	return nil
}
