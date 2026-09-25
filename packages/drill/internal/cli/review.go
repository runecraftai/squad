package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/runecraftai/squad/packages/drill/internal/agent"
	"github.com/runecraftai/squad/packages/drill/internal/config"
	"github.com/runecraftai/squad/packages/drill/internal/git"
	"github.com/runecraftai/squad/packages/drill/internal/paths"
	"github.com/runecraftai/squad/packages/drill/internal/pipeline/steps"
	"github.com/runecraftai/squad/packages/drill/internal/types"
	"github.com/spf13/cobra"
)

var standaloneReviewAgentFactory = func(ctx context.Context, cfg *config.Config) (agent.Agent, error) {
	if err := cfg.ResolveAgent(ctx, exec.LookPath); err != nil {
		return nil, err
	}
	return agent.NewWithOptions(cfg.Agent, cfg.AgentPath(), cfg.AgentArgsFor(cfg.Agent), agent.Options{DisableProjectSettings: true, ACPRegistryOverrides: cfg.ACPRegistryOverrides})
}

type standaloneReviewResult struct {
	Repository string         `json:"repository"`
	BaseSHA    string         `json:"base_sha"`
	HeadSHA    string         `json:"head_sha"`
	Findings   types.Findings `json:"findings"`
}

func newReviewCmd() *cobra.Command {
	var base, head, intent, format string
	cmd := &cobra.Command{
		Use:   "review",
		Short: "Review a local base..head range without running delivery",
		Long:  "Run the specialized read-only review engine over local refs. This audit never approves a delivery run.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if base == "" || head == "" {
				return fmt.Errorf("--base and --head are required")
			}
			if format != "text" && format != "json" {
				return fmt.Errorf("--format must be text or json")
			}
			root, err := git.FindGitRoot(".")
			if err != nil {
				return fmt.Errorf("not inside a git repository")
			}
			baseSHA, err := git.Run(cmd.Context(), root, "rev-parse", "--verify", base+"^{commit}")
			if err != nil {
				return fmt.Errorf("resolve base ref: %w", err)
			}
			headSHA, err := git.Run(cmd.Context(), root, "rev-parse", "--verify", head+"^{commit}")
			if err != nil {
				return fmt.Errorf("resolve head ref: %w", err)
			}
			baseSHA, headSHA = strings.TrimSpace(baseSHA), strings.TrimSpace(headSHA)
			if baseSHA == headSHA {
				return fmt.Errorf("base and head resolve to the same commit")
			}
			tmp, err := os.MkdirTemp("", "drill-review-")
			if err != nil {
				return err
			}
			defer os.RemoveAll(tmp)
			worktree := filepath.Join(tmp, "checkout")
			if _, err := git.Run(cmd.Context(), root, "worktree", "add", "--detach", "--quiet", worktree, headSHA); err != nil {
				return fmt.Errorf("create disposable review checkout: %w", err)
			}
			defer func() {
				if _, err := git.Run(context.Background(), root, "worktree", "remove", "--force", worktree); err != nil {
					_ = os.RemoveAll(worktree)
					_, _ = git.Run(context.Background(), root, "worktree", "prune")
				}
			}()
			p, err := paths.New()
			if err != nil {
				return err
			}
			global, err := config.LoadGlobal(p.ConfigFile())
			if err != nil {
				return err
			}
			cfg := config.Merge(global, &config.RepoConfig{})
			ag, err := standaloneReviewAgentFactory(cmd.Context(), cfg)
			if err != nil {
				return err
			}
			defer ag.Close()
			findings, err := steps.RunStandaloneReview(cmd.Context(), ag, worktree, baseSHA, headSHA, intent, cfg.Review.Topology.MaxParallel, cfg.Review.Topology.Timeout, func(line string) { fmt.Fprintln(cmd.ErrOrStderr(), line) })
			if err != nil {
				return err
			}
			result := standaloneReviewResult{Repository: root, BaseSHA: baseSHA, HeadSHA: headSHA, Findings: findings}
			if format == "json" {
				return json.NewEncoder(cmd.OutOrStdout()).Encode(result)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Repository: %s\nBase: %s\nHead: %s\n\n", root, baseSHA, headSHA)
			if findings.Summary != "" {
				fmt.Fprintln(cmd.OutOrStdout(), findings.Summary)
			}
			for _, finding := range findings.Items {
				fmt.Fprintf(cmd.OutOrStdout(), "- %s: %s\n", finding.Severity, finding.Description)
			}
			encoded, err := json.Marshal(result)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "\nFindings JSON:\n%s\n", encoded)
			return nil
		},
	}
	cmd.Flags().StringVar(&base, "base", "", "local base ref")
	cmd.Flags().StringVar(&head, "head", "", "local head ref")
	cmd.Flags().StringVar(&intent, "intent", "", "optional review intent")
	cmd.Flags().StringVar(&format, "format", "text", "output format: text or json")
	return cmd
}
