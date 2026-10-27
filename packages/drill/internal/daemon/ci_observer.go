package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/db"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
)

const ciObservationHealthInterval = 30 * time.Second
const ciObservationLeaseLimit = 20 * time.Second
const ciObservationLostWatcherGrace = 20 * time.Second

// StartCIObservationHealthScan supervises durable watcher liveness and absolute
// deadlines. The observer remains independent from execution ownership.
func (m *RunManager) StartCIObservationHealthScan(ctx context.Context) {
	go func() {
		ticker := time.NewTicker(ciObservationHealthInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				m.scanCIObservationHealth(time.Now().Unix())
			}
		}
	}()
}

func (m *RunManager) scanCIObservationHealth(at int64) {
	observations, err := m.db.ListWatchingCIObservations()
	if err != nil {
		slog.Error("CI observation health scan cannot read durable state", "error", err)
		return
	}
	for _, o := range observations {
		state, reason := "", ""
		if at >= o.DeadlineAt {
			state, reason = "expired", "observation_budget_expired"
		} else if o.LeaseUntil != nil && *o.LeaseUntil+int64(ciObservationHealthInterval.Seconds()) <= at {
			state, reason = "failed", "observation_poll_lease_expired"
		} else if o.LeaseUntil == nil && o.NextPollAt+int64(ciObservationLostWatcherGrace.Seconds()) <= at {
			state, reason = "failed", "observation_watcher_missing"
		}
		if state == "" {
			continue
		}
		n := &db.CINotification{RunID: o.RunID, Kind: "monitoring_failed", HeadSHA: o.HeadSHA, PRURL: o.PRURL, Summary: reason, DetailsJSON: fmt.Sprintf(`{"reason":%q}`, reason), CreatedAt: at}
		if err := m.db.FailCIObservation(o.RunID, o.PushGeneration, state, reason, at, n); err != nil {
			slog.Error("CI observation health failure could not be persisted", "run_id", o.RunID, "error", err)
			continue
		}
		status := state
		m.broadcast(ipc.Event{Type: ipc.EventCIObservationChanged, RunID: o.RunID, RepoID: "", Status: &status, Error: &reason})
		m.closeSubscribers(o.RunID)
	}
}
