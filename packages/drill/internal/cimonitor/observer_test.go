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
	const headA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const headB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	mergeabilityCaps := scm.Capabilities{MergeableState: true}
	passingChecks := []scm.Check{{Name: "build", Bucket: scm.CheckBucketPass}}
	failingChecks := []scm.Check{{Name: "build", Bucket: scm.CheckBucketFail}}
	pendingChecks := []scm.Check{{Name: "build", Bucket: scm.CheckBucketPending}}
	pr := &scm.PR{Number: "9", URL: "https://example.test/pr/9"}

	tests := []struct {
		name         string
		heads        []string
		state        scm.PRState
		candidate    string
		published    string
		merge        scm.MergeableState
		caps         scm.Capabilities
		checks       []scm.Check
		declaredNoCI bool
		wantVerdict  string
		wantReason   string
	}{
		{
			name:        "stable bound head is green",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			checks:      passingChecks,
			wantVerdict: "green",
		},
		{
			name:        "moved head is not green",
			heads:       []string{headA, headB},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			checks:      passingChecks,
			wantVerdict: "unknown",
			wantReason:  "PR or published head differs from observation candidate",
		},
		{
			name:        "unresolved mergeability is not green",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableUnknown,
			caps:        mergeabilityCaps,
			checks:      passingChecks,
			wantVerdict: "unknown",
			wantReason:  "PR mergeability is unresolved",
		},
		{
			name:        "provider without mergeability support cannot confirm green",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableOK,
			caps:        scm.Capabilities{MergeableState: false},
			checks:      passingChecks,
			wantVerdict: "unknown",
			wantReason:  "provider cannot positively resolve PR mergeability",
		},
		{
			name:        "failing check settles red without mergeability support",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   headA,
			caps:        scm.Capabilities{MergeableState: false},
			checks:      failingChecks,
			wantVerdict: "red",
		},
		{
			name:        "pending check settles pending without mergeability support",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   headA,
			caps:        scm.Capabilities{MergeableState: false},
			checks:      pendingChecks,
			wantVerdict: "pending",
		},
		{
			name:        "merged PR retires without head or mergeability reads",
			state:       scm.PRStateMerged,
			candidate:   headA,
			merge:       scm.MergeableOK,
			caps:        scm.Capabilities{MergeableState: false},
			checks:      passingChecks,
			wantVerdict: "unknown",
			wantReason:  "PR is not open",
		},
		{
			name:        "blank published head is not green",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   "",
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			checks:      passingChecks,
			wantVerdict: "unknown",
			wantReason:  "PR or published head is not a full commit SHA",
		},
		{
			name:        "malformed candidate head is not green",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   "abc",
			published:   headA,
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			checks:      passingChecks,
			wantVerdict: "unknown",
			wantReason:  "observation candidate head is not a full commit SHA",
		},
		{
			name:        "no checks without trusted no-CI policy is not green",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableOK,
			caps:        mergeabilityCaps,
			wantVerdict: "unknown",
			wantReason:  "provider reported no checks without trusted no-CI policy",
		},
		{
			name:         "no checks with trusted no-CI policy is green",
			heads:        []string{headA, headA},
			state:        scm.PRStateOpen,
			candidate:    headA,
			published:    headA,
			merge:        scm.MergeableOK,
			caps:         mergeabilityCaps,
			declaredNoCI: true,
			wantVerdict:  "green",
		},
		{
			name:        "merge conflict is red",
			heads:       []string{headA, headA},
			state:       scm.PRStateOpen,
			candidate:   headA,
			published:   headA,
			merge:       scm.MergeableConflict,
			caps:        mergeabilityCaps,
			checks:      passingChecks,
			wantVerdict: "red",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			reader := &observerReaderFake{
				heads:  append([]string(nil), tc.heads...),
				state:  tc.state,
				merge:  tc.merge,
				caps:   tc.caps,
				checks: tc.checks,
			}
			s, err := SampleBound(context.Background(), reader, pr,
				ObservationCandidate{HeadSHA: tc.candidate, PR: pr, DeclaredNoCI: tc.declaredNoCI},
				func(context.Context) (string, error) { return tc.published, nil },
				time.Second, nil)
			if err != nil {
				t.Fatalf("sample=%+v err=%v", s, err)
			}
			if s.Verdict != tc.wantVerdict {
				t.Fatalf("verdict=%q reason=%q, want %q", s.Verdict, s.Reason, tc.wantVerdict)
			}
			if tc.wantReason != "" && s.Reason != tc.wantReason {
				t.Fatalf("reason=%q, want %q", s.Reason, tc.wantReason)
			}
			if tc.state != scm.PRStateOpen && s.PRState != tc.state {
				t.Fatalf("PR state=%q, want %q", s.PRState, tc.state)
			}
		})
	}
}
