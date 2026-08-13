package cmd

import (
	"fmt"

	"github.com/fatih/color"
	"github.com/runecraftai/squad/packages/fob/internal/updater"
	"github.com/spf13/cobra"
)

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Update fob to the latest version",
	RunE: func(cmd *cobra.Command, args []string) error {
		if !updater.IsSemver(version) {
			fmt.Println("Skipping update: running a non-release build")
			return nil
		}

		fmt.Println("Checking for updates...")
		result, err := updater.CheckLatest(version)
		if err != nil {
			return fmt.Errorf("checking for updates: %w", err)
		}

		if !result.UpdateAvailable {
			fmt.Printf("fob is up to date (%s)\n", version)
			return nil
		}

		fmt.Printf("Updating %s → %s...\n", version, result.LatestVersion)
		if err := updater.Apply(result); err != nil {
			return fmt.Errorf("applying update: %w", err)
		}

		color.Green("Successfully updated fob %s → %s", version, result.LatestVersion)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(updateCmd)
}
