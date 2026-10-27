package cimonitor

import (
	"context"
	"testing"
	"time"

	"github.com/runecraftai/squad/packages/drill/internal/scm"
)

type observerReaderFake struct {
	heads  []string
	state  scm.PRState
	merge  scm.MergeableState
	checks []scm.Check
	caps   scm.Capabilities
}

func (f *observerReaderFake) Available(context.Context) error { return nil }
func (f *observerReaderFake) Capabilities() scm.Capabilities  { return f.caps }
func (f *observerReaderFake) GetPRState(context.Context, *scm.PR) (scm.PRState, error) {
	return f.state, nil
}
func (f *observerReaderFake) GetPRHeadSHA(context.Context, *scm.PR) (string, error) {
	h := f.heads[0]
	f.heads = f.heads[1:]
	return h, nil
}
func (f *observerReaderFake) GetChecks(context.Context, *scm.PR) ([]scm.Check, error) {
	return f.checks, nil
}
func (f *observerReaderFake) GetMergeableState(context.Context, *scm.PR) (scm.MergeableState, error) {
	return f.merge, nil
}

func TestPostGreenBoundSampleReadOnly(t *testing.T) {
	pr := &scm.PR{Number: "9", URL: "https://example.test/pr/9"}
	reader := &observerReaderFake{heads: []string{"abc", "abc"}, state: scm.PRStateOpen, merge: scm.MergeableOK, caps: scm.Capabilities{MergeableState: true}, checks: []scm.Check{{Name: "build", Bucket: scm.CheckBucketPass}}}
	s, err := SampleBound(context.Background(), reader, pr, ObservationCandidate{HeadSHA: "abc", PR: pr}, func(context.Context) (string, error) { return "abc", nil }, time.Second, nil)
	if err != nil || s.Verdict != "green" {
		t.Fatalf("sample=%+v err=%v", s, err)
	}
	reader.heads = []string{"abc", "def"}
	s, err = SampleBound(context.Background(), reader, pr, ObservationCandidate{HeadSHA: "abc"}, func(context.Context) (string, error) { return "abc", nil }, time.Second, nil)
	if err != nil || s.Verdict == "green" {
		t.Fatalf("moved head accepted: %+v err=%v", s, err)
	}
	reader.heads = []string{"abc", "abc"}
	reader.merge = scm.MergeableUnknown
	s, err = SampleBound(context.Background(), reader, pr, ObservationCandidate{HeadSHA: "abc"}, func(context.Context) (string, error) { return "abc", nil }, time.Second, nil)
	if err != nil || s.Verdict == "green" {
		t.Fatalf("unknown mergeability accepted: %+v err=%v", s, err)
	}
}
