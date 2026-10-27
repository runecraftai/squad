package cli

import (
	"fmt"
	"strings"

	"github.com/runecraftai/squad/packages/drill/internal/telemetry"
	"github.com/spf13/cobra"
	toon "github.com/toon-format/toon-go"
)

// newAxiNotificationsCmd reads durable observer records directly from SQLite;
// it deliberately does not connect to or start the daemon.
func newAxiNotificationsCmd() *cobra.Command {
	var runID string
	cmd := &cobra.Command{
		Use:           "notifications",
		Short:         "List durable CI observation notifications",
		Args:          cobra.NoArgs,
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return trackReadSurface("axi-notifications", telemetry.Fields{"explicit_run_id": strings.TrimSpace(runID) != ""}, func() (string, string, error) {
				return runAxiNotifications(cmd, runID)
			})
		},
	}
	cmd.Flags().StringVar(&runID, "run", "", "run ID whose durable notifications should be listed")
	return cmd
}

func runAxiNotifications(cmd *cobra.Command, runID string) (string, string, error) {
	if strings.TrimSpace(runID) == "" {
		return "", "", emitError(cmd, 1, "--run is required")
	}
	env, err := openAxiQueryEnv(runID)
	if err != nil {
		return "", "", emitError(cmd, 1, err.Error(), repoInitHelp(err)...)
	}
	defer env.close()
	items, err := env.d.ListCINotifications(runID)
	if err != nil {
		return "", "", emitError(cmd, 1, fmt.Sprintf("read notifications: %v", err))
	}
	fields := make([]toon.Field, 0, len(items)+1)
	fields = append(fields, toon.Field{Key: "run_id", Value: runID})
	for i, item := range items {
		fields = append(fields, toon.Field{Key: fmt.Sprintf("notification_%d", i+1), Value: item})
	}
	emitDoc(cmd, fields...)
	return runID + "|notifications|" + fmt.Sprint(len(items)), "", nil
}
