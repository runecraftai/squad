package steps

import (
	"context"
	"fmt"
	"os/exec"

	"github.com/runecraftai/squad/packages/drill/internal/bitbucket"
	"github.com/runecraftai/squad/packages/drill/internal/cimonitor"
	"github.com/runecraftai/squad/packages/drill/internal/pipeline"
	"github.com/runecraftai/squad/packages/drill/internal/scm"
	"github.com/runecraftai/squad/packages/drill/internal/scm/azuredevops"
	"github.com/runecraftai/squad/packages/drill/internal/scm/github"
	"github.com/runecraftai/squad/packages/drill/internal/scm/gitlab"
)

// buildHost returns a scm.Host for the given provider, wired to sctx's
// working directory and environment. When the host cannot be constructed
// (unknown provider, missing Bitbucket config, etc) it returns nil and a
// human-readable skip reason suitable for logging.
func buildHost(sctx *pipeline.StepContext, provider scm.Provider) (scm.Host, string) {
	return buildHostWithFactory(sctx, provider, func(ctx context.Context, name string, args ...string) *exec.Cmd {
		return stepCmdContext(sctx, ctx, name, args...)
	})
}

func buildHostWithFactory(sctx *pipeline.StepContext, provider scm.Provider, cmdFactory func(context.Context, string, ...string) *exec.Cmd) (scm.Host, string) {
	switch provider {
	case scm.ProviderGitHub:
		// Resolve the slug so gh commands carry --repo and work from the
		// daemon's fixed (non-repo) working directory. For GitHub Enterprise
		// Server, HostPrefixedSlug returns "host/owner/name" which is the
		// format gh requires for --repo on GHE. Fall back to the PR URL when
		// the upstream remote URL is unavailable. The hostname also scopes
		// the auth-status check so a stale token on any other configured gh
		// host cannot make this repo look unauthenticated.
		host := scm.ResolveHost(sctx.Ctx, sctx.Repo.UpstreamURL)
		repo := github.HostPrefixedSlugForHost(sctx.Repo.UpstreamURL, host)
		if repo == "" && sctx.Run.PRURL != nil {
			prHost := scm.ResolveHost(sctx.Ctx, *sctx.Run.PRURL)
			repo = github.HostPrefixedSlugForHost(*sctx.Run.PRURL, prHost)
			if host == "" {
				host = prHost
			}
		}
		forkRepo := ""
		if sctx.Repo.ForkURL != "" {
			// forkRepo is only used to extract the fork owner for --head owner:branch;
			// the plain slug (without host prefix) is correct here.
			forkRepo = github.RepoSlug(sctx.Repo.ForkURL)
		}
		return github.NewWithFork(cmdFactory, func() bool { return stepCLIAvailable(sctx, provider) }, host, repo, forkRepo), ""
	case scm.ProviderGitLab:
		if sctx.Repo.ForkURL != "" {
			// Fork MR routing for GitLab is intentionally not half-wired.
			// The push step may use fork_url, but PR creation must skip until
			// GitLab source-project routing is implemented end to end.
			return nil, "fork PR routing for GitLab is not implemented"
		}
		return gitlab.New(
			cmdFactory,
			func() bool { return stepCLIAvailable(sctx, provider) },
			scm.ResolveHost(sctx.Ctx, sctx.Repo.UpstreamURL),
			gitlab.ProjectPath(sctx.Repo.UpstreamURL),
		), ""
	case scm.ProviderBitbucket:
		if sctx.Repo.ForkURL != "" {
			// Fork PR routing for Bitbucket is intentionally not half-wired.
			// The API needs distinct source and destination repositories before
			// this provider can safely consume fork_url for PR creation.
			return nil, "fork PR routing for Bitbucket is not implemented"
		}
		client, err := bitbucket.NewClientFromEnv(sctx.Env)
		if err != nil {
			return nil, err.Error()
		}
		repo, err := resolveBitbucketRepoRef(sctx.Repo.UpstreamURL, sctx.Run.PRURL)
		if err != nil {
			return nil, err.Error()
		}
		return bitbucket.NewHost(client, repo), ""
	case scm.ProviderAzureDevOps:
		if sctx.Repo.ForkURL != "" {
			// Fork PR routing for Azure DevOps is intentionally not half-wired,
			// mirroring GitLab and Bitbucket: the push step may use fork_url, but
			// PR creation must skip until cross-repository routing is implemented
			// end to end.
			return nil, "fork PR routing for Azure DevOps is not implemented"
		}
		org, project, repo, ok := azuredevops.ParseRemote(sctx.Repo.UpstreamURL)
		if !ok && sctx.Run.PRURL != nil {
			org, project, repo, ok = azuredevops.ParseRemote(*sctx.Run.PRURL)
		}
		if !ok {
			return nil, "could not resolve Azure DevOps organization, project, and repository from the remote URL"
		}
		return azuredevops.New(cmdFactory, func() bool { return stepCLIAvailable(sctx, provider) }, org, project, repo), ""
	default:
		return nil, fmt.Sprintf("provider %s is not supported yet", provider)
	}
}

// observerReader deliberately hides provider write operations from observation.
type observerReader struct {
	host  scm.Host
	heads scm.PRHeadReader
}

func (r observerReader) Available(ctx context.Context) error { return r.host.Available(ctx) }
func (r observerReader) Capabilities() scm.Capabilities      { return r.host.Capabilities() }
func (r observerReader) GetPRState(ctx context.Context, pr *scm.PR) (scm.PRState, error) {
	return r.host.GetPRState(ctx, pr)
}
func (r observerReader) GetPRHeadSHA(ctx context.Context, pr *scm.PR) (string, error) {
	return r.heads.GetPRHeadSHA(ctx, pr)
}
func (r observerReader) GetChecks(ctx context.Context, pr *scm.PR) ([]scm.Check, error) {
	return r.host.GetChecks(ctx, pr)
}
func (r observerReader) GetMergeableState(ctx context.Context, pr *scm.PR) (scm.MergeableState, error) {
	return r.host.GetMergeableState(ctx, pr)
}

// BuildObserverReader builds the narrow read-only API. Its StepContext must
// identify the stable gate directory rather than a cleaned execution copy.
func BuildObserverReader(sctx *pipeline.StepContext, provider scm.Provider) (cimonitor.Reader, string) {
	return BuildObserverReaderWithFactory(sctx, provider, func(ctx context.Context, name string, args ...string) *exec.Cmd {
		return stepCmdContext(sctx, ctx, name, args...)
	})
}

// BuildObserverReaderWithFactory accepts the per-call command factory so
// observation deadlines cancel provider subprocesses using the sample context.
func BuildObserverReaderWithFactory(sctx *pipeline.StepContext, provider scm.Provider, factory func(context.Context, string, ...string) *exec.Cmd) (cimonitor.Reader, string) {
	host, reason := buildHostWithFactory(sctx, provider, factory)
	if host == nil {
		return nil, reason
	}
	headReader, ok := host.(scm.PRHeadReader)
	if !ok {
		return nil, fmt.Sprintf("provider %s cannot read PR source head", provider)
	}
	return observerReader{host: host, heads: headReader}, ""
}
