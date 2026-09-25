package types

import (
	"testing"
)

func TestParseSpecializedReviewProgress_EmptyLog(t *testing.T) {
	result := ParseSpecializedReviewProgress(nil, 0)
	if result != nil {
		t.Fatalf("expected nil for empty log, got %+v", result)
	}
}

func TestParseSpecializedReviewProgress_ReportsMonoAgentMode(t *testing.T) {
	result := ParseSpecializedReviewProgress([]string{"review mode=mono-agent enforcement=observe"}, 0)
	if result == nil || result.Mode != "mono-agent" {
		t.Fatalf("review mode = %+v, want mono-agent", result)
	}
}

func TestParseSpecializedReviewProgress_TopologyOnly(t *testing.T) {
	lines := []string{
		"specialized review topology=full enforcement=strict snapshot_head=abc123def",
	}
	result := ParseSpecializedReviewProgress(lines, 0)
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result.Topology != "full" {
		t.Errorf("expected topology=full, got %q", result.Topology)
	}
	if result.Enforcement != "strict" {
		t.Errorf("expected enforcement=strict, got %q", result.Enforcement)
	}
	if result.SnapshotHEAD != "abc123def" {
		t.Errorf("expected snapshot_head=abc123def, got %q", result.SnapshotHEAD)
	}
}

func TestParseSpecializedReviewProgress_BatchWithLenses(t *testing.T) {
	lines := []string{
		"specialized review topology=full enforcement=strict snapshot_head=abc123def",
		"specialized review batch b-001 pending at HEAD abc123def: source, test",
		"review lens source completed: 42",
		"review lens test pending",
	}
	result := ParseSpecializedReviewProgress(lines, 0)
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result.BatchID != "b-001" {
		t.Errorf("expected batch_id=b-001, got %q", result.BatchID)
	}
	if len(result.Lenses) != 2 {
		t.Fatalf("expected 2 lenses, got %d", len(result.Lenses))
	}
	if result.Lenses[0].Lens != "source" || result.Lenses[0].Status != "completed" || result.Lenses[0].Candidates != 42 {
		t.Errorf("expected source lens completed with 42 candidates, got %+v", result.Lenses[0])
	}
	if result.Lenses[1].Lens != "test" || result.Lenses[1].Status != "pending" || result.Lenses[1].Candidates != 0 {
		t.Errorf("expected test lens pending with 0 candidates, got %+v", result.Lenses[1])
	}
}

func TestParseSpecializedReviewProgress_Consolidator(t *testing.T) {
	lines := []string{
		"specialized review topology=full enforcement=strict snapshot_head=abc",
		"specialized review batch b-001 pending at HEAD abc: source",
		"specialized review consolidator running",
		"specialized review consolidator completed: all findings merged",
	}
	result := ParseSpecializedReviewProgress(lines, 0)
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result.Consolidator != "completed: all findings merged" {
		t.Errorf("expected consolidator completed, got %q", result.Consolidator)
	}
}

func TestParseSpecializedReviewProgress_ConsolidatorFailed(t *testing.T) {
	lines := []string{
		"specialized review topology=full enforcement=strict snapshot_head=abc",
		"specialized review batch b-001 pending at HEAD abc: source",
		"specialized review consolidator failed",
	}
	result := ParseSpecializedReviewProgress(lines, 0)
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result.Consolidator != "failed" {
		t.Errorf("expected consolidator failed, got %q", result.Consolidator)
	}
}

func TestParseSpecializedReviewProgress_WallTime(t *testing.T) {
	lines := []string{
		"specialized review topology=full enforcement=strict snapshot_head=abc",
		"specialized review batch b-001 pending at HEAD abc: source",
		"specialized review batch completed in 5.2s: 10 findings",
	}
	result := ParseSpecializedReviewProgress(lines, 0)
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result.WallTime != "5.2s" {
		t.Errorf("expected wall_time=5.2s, got %q", result.WallTime)
	}
}

func TestParseSpecializedReviewProgress_IncompleteTruncation(t *testing.T) {
	longReason := make([]byte, 200)
	for i := range longReason {
		longReason[i] = 'a'
	}
	lines := []string{
		"specialized review topology=full enforcement=strict snapshot_head=abc",
		"specialized review batch b-001 pending at HEAD abc: source",
		"specialized review incomplete: " + string(longReason),
	}
	result := ParseSpecializedReviewProgress(lines, 120)
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if len(result.Incomplete) != 120 {
		t.Errorf("expected incomplete truncated to 120 chars, got %d", len(result.Incomplete))
	}
}

func TestParseSpecializedReviewProgress_IncompleteNoTruncation(t *testing.T) {
	longReason := make([]byte, 200)
	for i := range longReason {
		longReason[i] = 'a'
	}
	lines := []string{
		"specialized review topology=full enforcement=strict snapshot_head=abc",
		"specialized review batch b-001 pending at HEAD abc: source",
		"specialized review incomplete: " + string(longReason),
	}
	result := ParseSpecializedReviewProgress(lines, 0)
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if len(result.Incomplete) != 200 {
		t.Errorf("expected incomplete not truncated (limit=0), got %d chars", len(result.Incomplete))
	}
}

func TestParseSpecializedReviewProgress_BatchResetsState(t *testing.T) {
	lines := []string{
		"specialized review topology=full enforcement=strict snapshot_head=abc",
		"specialized review batch b-001 pending at HEAD abc: source",
		"review lens source completed: 42",
		"specialized review consolidator running",
		"specialized review incomplete: something",
		"specialized review batch b-002 pending at HEAD abc: test",
	}
	result := ParseSpecializedReviewProgress(lines, 0)
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	if result.BatchID != "b-002" {
		t.Errorf("expected batch_id=b-002, got %q", result.BatchID)
	}
	if len(result.Lenses) != 1 || result.Lenses[0].Lens != "test" {
		t.Errorf("expected single test lens, got %+v", result.Lenses)
	}
	if result.Consolidator != "" {
		t.Errorf("expected consolidator reset, got %q", result.Consolidator)
	}
	if result.Incomplete != "" {
		t.Errorf("expected incomplete reset, got %q", result.Incomplete)
	}
}
