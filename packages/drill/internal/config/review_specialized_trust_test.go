package config

import "testing"

func TestEffectiveRepoConfig_ReviewTopologyTrustedOnly(t *testing.T) {
	pushed := &RepoConfig{}
	pushed.Review.TopologyConfig = ReviewTopologyConfig{Topology: ReviewTopologySpecialized, Enforcement: ReviewEnforcementBlocking, MaxParallel: 1}
	trusted := &RepoConfig{}
	effective := EffectiveRepoConfig(pushed, trusted, false)
	if effective.Review.TopologyConfig.Topology != "" {
		t.Fatalf("pushed topology survived: %#v", effective.Review)
	}
	trusted.Review.TopologyConfig = ReviewTopologyConfig{Topology: ReviewTopologySpecialized, Enforcement: ReviewEnforcementObserve, MaxParallel: 3}
	effective = EffectiveRepoConfig(pushed, trusted, false)
	if effective.Review.TopologyConfig != trusted.Review.TopologyConfig {
		t.Fatalf("effective review = %#v, want trusted %#v", effective.Review, trusted.Review)
	}
}
