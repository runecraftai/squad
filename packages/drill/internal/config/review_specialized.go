package config

import (
	"fmt"
	"time"
)

const (
	ReviewTopologySingle      = "single"
	ReviewTopologySpecialized = "specialized"
	ReviewEnforcementObserve  = "observe"
	ReviewEnforcementBlocking = "blocking"
	MaxReviewParallel         = 6
	MinReviewTimeout          = time.Minute
	MaxReviewTimeout          = 30 * time.Minute
)

var specializedReviewLenses = [...]string{"security", "requirements", "tests-behavior", "architecture", "regression-hallucination", "performance-resources"}

type ReviewTopologyConfig struct {
	Topology    string        `yaml:"topology"`
	Enforcement string        `yaml:"enforcement"`
	MaxParallel int           `yaml:"max_parallel"`
	Timeout     time.Duration `yaml:"-"`
	TimeoutRaw  string        `yaml:"timeout"`
}

type ReviewMode struct {
	Topology     string
	Enforcement  string
	MaxParallel  int
	Timeout      time.Duration
	Lenses       []string
	Consolidator bool
}

func (r ReviewTopologyConfig) Resolve() (ReviewMode, error) {
	topology := r.Topology
	if topology == "" {
		topology = ReviewTopologySingle
	}
	if topology != ReviewTopologySingle && topology != ReviewTopologySpecialized {
		return ReviewMode{}, fmt.Errorf("review.topology must be single or specialized")
	}
	enforcement := r.Enforcement
	if enforcement == "" {
		enforcement = ReviewEnforcementObserve
	}
	if enforcement != ReviewEnforcementObserve && enforcement != ReviewEnforcementBlocking {
		return ReviewMode{}, fmt.Errorf("review.enforcement must be observe or blocking")
	}
	parallel := r.MaxParallel
	if parallel == 0 {
		parallel = MaxReviewParallel
	}
	if parallel < 1 || parallel > MaxReviewParallel {
		return ReviewMode{}, fmt.Errorf("review.max_parallel must be between 1 and %d", MaxReviewParallel)
	}
	timeout := r.Timeout
	if timeout == 0 && r.TimeoutRaw != "" {
		parsed, err := time.ParseDuration(r.TimeoutRaw)
		if err != nil {
			return ReviewMode{}, fmt.Errorf("review.timeout: %w", err)
		}
		timeout = parsed
	}
	if timeout == 0 {
		timeout = 10 * time.Minute
	}
	if timeout < MinReviewTimeout || timeout > MaxReviewTimeout {
		return ReviewMode{}, fmt.Errorf("review.timeout must be between %s and %s", MinReviewTimeout, MaxReviewTimeout)
	}
	mode := ReviewMode{Topology: topology, Enforcement: enforcement, MaxParallel: parallel, Timeout: timeout}
	if topology == ReviewTopologySpecialized {
		mode.Lenses = append([]string(nil), specializedReviewLenses[:]...)
		mode.Consolidator = true
	}
	return mode, nil
}

func ReviewModeString(topology, enforcement string) string {
	if topology == ReviewTopologySpecialized {
		if enforcement == ReviewEnforcementBlocking {
			return "specialized-blocking"
		}
		return "specialized-shadow"
	}
	return "mono-agent"
}
