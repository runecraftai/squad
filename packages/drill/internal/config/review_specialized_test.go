package config

import (
	"reflect"
	"testing"
	"time"
)

func TestReviewTopologyConfig_Resolve(t *testing.T) {
	mode, err := (ReviewTopologyConfig{Topology: ReviewTopologySpecialized}).Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(mode.Lenses, specializedReviewLenses[:]) || !mode.Consolidator {
		t.Fatalf("specialized topology = %#v", mode)
	}
	if mode.MaxParallel != MaxReviewParallel || mode.Timeout != 10*time.Minute {
		t.Fatalf("defaults = %#v", mode)
	}
	mode.Lenses[0] = "changed"
	otherMode, err := (ReviewTopologyConfig{Topology: ReviewTopologySpecialized}).Resolve()
	if err != nil || otherMode.Lenses[0] != "security" {
		t.Fatalf("resolved lenses are not isolated: %#v, %v", otherMode, err)
	}
	for _, timeout := range []time.Duration{MinReviewTimeout, MaxReviewTimeout} {
		if _, err := (ReviewTopologyConfig{Timeout: timeout}).Resolve(); err != nil {
			t.Errorf("bound timeout %s rejected: %v", timeout, err)
		}
	}
	for _, enforcement := range []string{ReviewEnforcementObserve, ReviewEnforcementBlocking} {
		if _, err := (ReviewTopologyConfig{Enforcement: enforcement}).Resolve(); err != nil {
			t.Errorf("enforcement %q rejected: %v", enforcement, err)
		}
	}
	for _, tc := range []ReviewTopologyConfig{
		{Topology: "invented"}, {Enforcement: "invented"}, {MaxParallel: MaxReviewParallel + 1}, {MaxParallel: -1}, {Timeout: MaxReviewTimeout + time.Second}, {Timeout: MinReviewTimeout - time.Second},
	} {
		if _, err := tc.Resolve(); err == nil {
			t.Errorf("Resolve(%#v) accepted invalid value", tc)
		}
	}
}

func TestReviewTopologyConfig_ParseRepoYAML(t *testing.T) {
	repo, err := parseRepoConfig([]byte(`review:
  topology: specialized
  enforcement: blocking
  max_parallel: 4
  timeout: 5m
`))
	if err != nil {
		t.Fatal(err)
	}
	if repo.Review.TopologyConfig.Topology != ReviewTopologySpecialized || repo.Review.TopologyConfig.Enforcement != ReviewEnforcementBlocking || repo.Review.TopologyConfig.MaxParallel != 4 || repo.Review.TopologyConfig.TimeoutRaw != "5m" {
		t.Fatalf("parsed review topology = %#v", repo.Review.TopologyConfig)
	}
}
