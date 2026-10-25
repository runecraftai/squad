//go:build e2e

package executionpolicy

import "testing"

func TestE2EBuildGivesFixtureAccessRegardlessOfBinaryName(t *testing.T) {
	policy, root, repo, fixture := newFixtureAccessFixture(t)
	for _, name := range []string{"fakeagent", "synthetic-agent"} {
		if !fixtureGrantedToNamedBinary(t, policy, root, repo, fixture, name) {
			t.Fatalf("e2e build withheld fixture access from binary %q", name)
		}
	}
}
