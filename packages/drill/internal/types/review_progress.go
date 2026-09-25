package types

import (
	"fmt"
	"strings"
	"time"
)

// ReviewLensProgress represents the progress of a single lens in a specialized review batch.
type ReviewLensProgress struct {
	Lens       string
	Status     string
	Candidates int
}

// SpecializedReviewProgress holds the parsed state from specialized review operational logs.
// It exposes bounded, privacy-safe operational telemetry without agent output.
type SpecializedReviewProgress struct {
	Mode         string
	BatchID      string
	WallTime     string
	Topology     string
	Enforcement  string
	SnapshotHEAD string
	Lenses       []ReviewLensProgress
	Consolidator string
	Incomplete   string
}

// ParseSpecializedReviewProgress parses specialized review operational log lines into structured state.
// It returns nil when the log contains no recognizable topology or lens events.
// incompleteLimit truncates the incomplete reason to at most incompleteLimit characters;
// pass 0 to disable truncation.
func ParseSpecializedReviewProgress(lines []string, incompleteLimit int) *SpecializedReviewProgress {
	progress := &SpecializedReviewProgress{}
	lensIndexes := make(map[string]int)

	for _, line := range lines {
		fields := strings.Fields(line)
		switch {
		case strings.HasPrefix(line, "review mode="):
			for _, field := range fields {
				key, value, ok := strings.Cut(field, "=")
				if ok && key == "mode" {
					progress.Mode = value
				}
			}
		case strings.HasPrefix(line, "specialized review topology="):
			for _, field := range fields {
				key, value, ok := strings.Cut(field, "=")
				if !ok {
					continue
				}
				switch key {
				case "topology":
					progress.Topology = value
				case "enforcement":
					progress.Enforcement = value
				case "snapshot_head":
					progress.SnapshotHEAD = value
				}
			}
		case strings.HasPrefix(line, "specialized review batch ") && strings.Contains(line, " pending at HEAD "):
			progress.Lenses = nil
			lensIndexes = make(map[string]int)
			progress.Consolidator = ""
			progress.Incomplete = ""
			progress.WallTime = ""
			if len(fields) >= 4 {
				progress.BatchID = fields[3]
			}
			if _, after, ok := strings.Cut(line, ": "); ok {
				for _, name := range strings.Split(after, ",") {
					name = strings.TrimSpace(name)
					if name != "" {
						lensIndexes[name] = len(progress.Lenses)
						progress.Lenses = append(progress.Lenses, ReviewLensProgress{Lens: name, Status: "pending"})
					}
				}
			}
		case strings.HasPrefix(line, "review lens ") && len(fields) >= 4:
			name := fields[2]
			if i, ok := lensIndexes[name]; ok {
				progress.Lenses[i].Status = fields[3]
				if fields[3] == "completed:" && len(fields) >= 5 {
					progress.Lenses[i].Status = "completed"
					fmt.Sscanf(fields[4], "%d", &progress.Lenses[i].Candidates)
				}
			}
		case line == "specialized review consolidator running":
			progress.Consolidator = "running"
		case strings.HasPrefix(line, "specialized review consolidator completed:"):
			progress.Consolidator = strings.TrimPrefix(line, "specialized review consolidator ")
		case strings.HasPrefix(line, "specialized review consolidator failed"):
			progress.Consolidator = "failed"
		case strings.HasPrefix(line, "specialized review batch completed in "):
			value := strings.TrimPrefix(line, "specialized review batch completed in ")
			if duration, _, ok := strings.Cut(value, ":"); ok {
				if _, err := time.ParseDuration(duration); err == nil {
					progress.WallTime = duration
				}
			}
		case strings.HasPrefix(line, "specialized review incomplete:"):
			progress.Incomplete = strings.TrimPrefix(line, "specialized review incomplete: ")
			if incompleteLimit > 0 && len(progress.Incomplete) > incompleteLimit {
				progress.Incomplete = progress.Incomplete[:incompleteLimit]
			}
		}
	}

	if progress.Mode == "" && progress.Topology == "" && len(progress.Lenses) == 0 {
		return nil
	}
	return progress
}
