package cimonitor

import (
	"context"
	"strings"
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
	const headA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const headB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	mergeabilityCaps := scm.Capabilities{MergeableState: true}
	passingChecks := []scm.Check{{Name: "build", Bucket: scm.CheckBucketPass}}
	pr := &scm.PR{Number: "9", URL: "https://example.test/pr/9"}

	tests := []struct {
		name         string
		heads        []string
		candidate    string
		published    string
		merge        scm.MergeableState
		caps         scm.Capabilities
		declaredNoCI bool
		wantVerdict  string
		wantReason   string
		wantErr      bool
	}{
		{
			name:        "stable bound head is green",
			heads:       []string{headA, headA},
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			wantVerdict: "green",
		},
		{
			name:        "moved head is not green",
			heads:       []string{headA, headB},
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			wantVerdict: "unknown",
			wantReason:  "PR or published head differs from observation candidate",
		},
		{
			name:        "unresolved mergeability is not green",
			heads:       []string{headA, headA},
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableUnknown,
			caps:        mergeabilityCaps,
			wantVerdict: "unknown",
			wantReason:  "PR mergeability is unresolved",
		},
		{
			name:       "provider without mergeability support cannot sample green",
			heads:      []string{headA},
			candidate:  headA,
			published:  headA,
			merge:      scm.MergeableOK,
			caps:       scm.Capabilities{MergeableState: false},
			wantErr:    true,
			wantReason: "provider cannot positively resolve PR mergeability",
		},
		{
			name:        "blank published head is not green",
			heads:       []string{headA, headA},
			candidate:   headA,
			published:   "",
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			wantVerdict: "unknown",
			wantReason:  "PR or published head is not a full commit SHA",
		},
		{
			name:        "malformed candidate head is not green",
			heads:       []string{headA, headA},
			candidate:   "abc",
			published:   headA,
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			wantVerdict: "unknown",
			wantReason:  "observation candidate head is not a full commit SHA",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			reader := &observerReaderFake{
				heads:  append([]string(nil), tc.heads...),
				state:  scm.PRStateOpen,
				merge:  tc.merge,
				caps:   tc.caps,
				checks: passingChecks,
			}
			s, err := SampleBound(context.Background(), reader, pr,
				ObservationCandidate{HeadSHA: tc.candidate, PR: pr, DeclaredNoCI: tc.declaredNoCI},
				func(context.Context) (string, error) { return tc.published, nil },
				time.Second, nil)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("sample accepted without a positive mergeability capability: %+v", s)
				}
				if s.Verdict == "green" {
					t.Fatalf("failed read reported green: %+v", s)
				}
				if tc.wantReason != "" && !strings.Contains(err.Error(), tc.wantReason) {
					t.Fatalf("error=%q, want %q", err, tc.wantReason)
				}
			} else {
				if err != nil {
					t.Fatalf("sample=%+v err=%v", s, err)
				}
				if s.Verdict != tc.wantVerdict {
					t.Fatalf("verdict=%q reason=%q, want %q", s.Verdict, s.Reason, tc.wantVerdict)
				}
				if tc.wantReason != "" && s.Reason != tc.wantReason {
					t.Fatalf("reason=%q, want %q", s.Reason, tc.wantReason)
				}
			}
		})
	}
}
