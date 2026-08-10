package bitbucket

import (
	"slices"
	"testing"

	"github.com/runecraftai/squad/packages/no-mistakes/internal/scm"
)

func TestNormalizePRState(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want scm.PRState
	}{
		{"open canonical", "OPEN", scm.PRStateOpen},
		{"open lowercase", "open", scm.PRStateOpen},
		{"open mixed case", "Open", scm.PRStateOpen},
		{"open with surrounding whitespace", "  OPEN  ", scm.PRStateOpen},
		{"merged canonical", "MERGED", scm.PRStateMerged},
		{"merged lowercase", "merged", scm.PRStateMerged},
		{"merged with whitespace", "\tMERGED\n", scm.PRStateMerged},
		{"declined canonical", "DECLINED", scm.PRStateClosed},
		{"declined lowercase", "declined", scm.PRStateClosed},
		{"closed canonical", "CLOSED", scm.PRStateClosed},
		{"closed lowercase", "closed", scm.PRStateClosed},
		{"superseded canonical", "SUPERSEDED", scm.PRStateClosed},
		{"superseded lowercase", "superseded", scm.PRStateClosed},

		// The default branch returns the raw string verbatim: no trim, no case fold.
		// Unknown lifecycle states pass through untouched so callers can surface them.
		{"unknown state passes through raw", "DRAFT", "DRAFT"},
		{"unknown state preserves original casing", "Draft", "Draft"},
		{"unknown state preserves original whitespace", "  Draft  ", "  Draft  "},
		{"empty string stays empty", "", ""},
		{"whitespace-only with no recognized token returns raw", "   ", "   "},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizePRState(tt.raw)
			if got != tt.want {
				t.Fatalf("normalizePRState(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}

func TestStatusName(t *testing.T) {
	tests := []struct {
		name   string
		status CommitStatus
		want   string
	}{
		{"name present", CommitStatus{Name: "build", Key: "build-key"}, "build"},
		{"name takes precedence over key", CommitStatus{Name: "build", Key: "other"}, "build"},
		{"name empty falls back to key", CommitStatus{Name: "", Key: "build-key"}, "build-key"},
		{"name whitespace-only falls back to key", CommitStatus{Name: "   ", Key: "build-key"}, "build-key"},
		{"name trimmed when returned", CommitStatus{Name: "  build  ", Key: ""}, "build"},
		{"key trimmed when used as fallback", CommitStatus{Name: "", Key: "  build-key  "}, "build-key"},
		{"both empty returns empty", CommitStatus{}, ""},
		{"both whitespace-only returns empty", CommitStatus{Name: "  ", Key: "  "}, ""},
		{"neither name nor key set but state populated returns empty", CommitStatus{State: "SUCCESSFUL"}, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := statusName(tt.status)
			if got != tt.want {
				t.Fatalf("statusName(%#v) = %q, want %q", tt.status, got, tt.want)
			}
		})
	}
}

func TestStatusBucket(t *testing.T) {
	tests := []struct {
		name  string
		state string
		want  scm.CheckBucket
	}{
		{"successful canonical", "SUCCESSFUL", scm.CheckBucketPass},
		{"success alias", "SUCCESS", scm.CheckBucketPass},
		{"successful lowercase", "successful", scm.CheckBucketPass},
		{"successful mixed case", "Successful", scm.CheckBucketPass},
		{"successful with whitespace", "  SUCCESSFUL  ", scm.CheckBucketPass},

		{"failed canonical", "FAILED", scm.CheckBucketFail},
		{"failure alias", "FAILURE", scm.CheckBucketFail},
		{"error alias", "ERROR", scm.CheckBucketFail},
		{"failed lowercase", "failed", scm.CheckBucketFail},

		{"stopped maps to cancel", "STOPPED", scm.CheckBucketCancel},
		{"stopped lowercase", "stopped", scm.CheckBucketCancel},

		{"inprogress no underscore", "INPROGRESS", scm.CheckBucketPending},
		{"in_progress with underscore", "IN_PROGRESS", scm.CheckBucketPending},
		{"pending", "PENDING", scm.CheckBucketPending},
		{"inprogress lowercase", "inprogress", scm.CheckBucketPending},

		{"unknown returns empty", "UNKNOWN", ""},
		{"empty returns empty", "", ""},
		{"whitespace-only returns empty", "   ", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := statusBucket(tt.state)
			if got != tt.want {
				t.Fatalf("statusBucket(%q) = %q, want %q", tt.state, got, tt.want)
			}
		})
	}
}

func TestNormalizePipelineUUID(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{"already lowercase", "abc-def-123", "abc-def-123"},
		{"uppercase lowered", "ABC-DEF-123", "abc-def-123"},
		{"mixed case lowered", "AbC-dEf", "abc-def"},
		{"with braces stripped", "{abc-def-123}", "abc-def-123"},
		{"with braces uppercase", "{ABC-DEF}", "abc-def"},
		{"with surrounding spaces trimmed", "  abc-def  ", "abc-def"},
		{"spaces and braces combined", "  {abc-def}  ", "abc-def"},

		// strings.Trim with cutset "{}" strips all leading/trailing { and } chars,
		// not just one matched pair.
		{"nested braces collapse", "{{abc-def}}", "abc-def"},
		{"only leading brace stripped", "{abc-def", "abc-def"},
		{"only trailing brace stripped", "abc-def}", "abc-def"},
		{"triple trailing braces", "abc-def}}}", "abc-def"},
		{"interior braces preserved", "a{b}c", "a{b}c"},

		{"empty returns empty", "", ""},
		{"whitespace-only returns empty", "   ", ""},
		{"empty braces return empty", "{}", ""},
		{"braces with whitespace return empty", "  {}  ", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizePipelineUUID(tt.raw)
			if got != tt.want {
				t.Fatalf("normalizePipelineUUID(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}

func TestPipelineUUIDFromStatusURL(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "valid results URL with braces",
			raw:  "https://bitbucket.org/ws/repo/pipelines/results/{abc-def-123}",
			want: "abc-def-123",
		},
		{
			name: "UUID without braces",
			raw:  "https://bitbucket.org/ws/repo/pipelines/results/abc-def",
			want: "abc-def",
		},
		{
			name: "uppercase UUID normalized to lowercase",
			raw:  "https://bitbucket.org/ws/repo/pipelines/results/{ABC-DEF}",
			want: "abc-def",
		},
		{
			name: "URL with query string strips query",
			raw:  "https://bitbucket.org/ws/repo/pipelines/results/{abc-def}?tab=logs",
			want: "abc-def",
		},
		{
			name: "URL with trailing path segment stops at first slash",
			raw:  "https://bitbucket.org/ws/repo/pipelines/results/{abc-def}/steps",
			want: "abc-def",
		},
		{
			name: "fragment consulted before path",
			raw:  "https://bitbucket.org/ws/pipelines/results/path-uuid#/pipelines/results/frag-uuid",
			want: "frag-uuid",
		},
		{
			name: "last results segment wins when duplicated",
			raw:  "https://bitbucket.org/results/early/results/late",
			want: "late",
		},
		{
			name: "URL without results segment returns empty",
			raw:  "https://bitbucket.org/ws/repo/pipelines",
			want: "",
		},
		{
			name: "URL whose path lacks results but fragment has it extracts fragment UUID",
			raw:  "https://bitbucket.org/ws/repo#/pipelines/results/{frag-only}",
			want: "frag-only",
		},
		{
			name: "empty string returns empty",
			raw:  "",
			want: "",
		},
		{
			name: "whitespace-only returns empty",
			raw:  "   ",
			want: "",
		},
		{
			name: "plain string with no URL structure returns empty",
			raw:  "not-a-url",
			want: "",
		},
		{
			// An invalid percent-escape makes url.Parse fail outright; the helper
			// must return empty rather than panic or surface the parse error.
			name: "malformed URL with invalid percent escape returns empty",
			raw:  "https://bitbucket.org/x/results/{abc}%xx",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := pipelineUUIDFromStatusURL(tt.raw)
			if got != tt.want {
				t.Fatalf("pipelineUUIDFromStatusURL(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}

func TestFailedPipelineUUIDs(t *testing.T) {
	resultsURL := func(uuid string) string {
		return "https://bitbucket.org/ws/repo/pipelines/results/{" + uuid + "}"
	}

	tests := []struct {
		name         string
		statuses     []CommitStatus
		failingNames []string
		wantNil      bool
		want         []string // pre-sorted UUIDs expected in the returned map
	}{
		{
			name:         "no failing names returns nil",
			failingNames: nil,
			wantNil:      true,
		},
		{
			name:         "empty failing names slice returns nil",
			failingNames: []string{},
			wantNil:      true,
		},
		{
			name:         "failing names all whitespace returns nil",
			failingNames: []string{"  ", ""},
			wantNil:      true,
		},
		{
			name:         "no statuses returns nil",
			statuses:     nil,
			failingNames: []string{"build"},
			wantNil:      true,
		},
		{
			name: "no status name matches a failing name returns nil",
			statuses: []CommitStatus{
				{Name: "lint", URL: resultsURL("lint-uuid")},
			},
			failingNames: []string{"build"},
			wantNil:      true,
		},
		{
			name: "matching status with no results URL returns nil",
			statuses: []CommitStatus{
				{Name: "build", URL: "https://bitbucket.org/ws/repo/build"},
			},
			failingNames: []string{"build"},
			wantNil:      true,
		},
		{
			name: "matching status with empty URL returns nil",
			statuses: []CommitStatus{
				{Name: "build", URL: ""},
			},
			failingNames: []string{"build"},
			wantNil:      true,
		},
		{
			name: "single match extracts UUID",
			statuses: []CommitStatus{
				{Name: "build", URL: resultsURL("abc")},
			},
			failingNames: []string{"build"},
			want:         []string{"abc"},
		},
		{
			name: "multiple distinct failing names map to distinct UUIDs",
			statuses: []CommitStatus{
				{Name: "build", URL: resultsURL("abc")},
				{Name: "tests", URL: resultsURL("def")},
			},
			failingNames: []string{"build", "tests"},
			want:         []string{"abc", "def"},
		},
		{
			name: "duplicate UUIDs collapse into a single target",
			statuses: []CommitStatus{
				{Name: "build", URL: resultsURL("abc")},
				{Name: "tests", URL: resultsURL("abc")},
			},
			failingNames: []string{"build", "tests"},
			want:         []string{"abc"},
		},
		{
			name: "only the requested failing names contribute UUIDs",
			statuses: []CommitStatus{
				{Name: "build", URL: resultsURL("abc")},
				{Name: "lint", URL: resultsURL("def")},
			},
			failingNames: []string{"build", "nonexistent"},
			want:         []string{"abc"},
		},
		{
			name: "failing name with surrounding whitespace matches trimmed status name",
			statuses: []CommitStatus{
				{Name: "build", URL: resultsURL("abc")},
			},
			failingNames: []string{"  build  "},
			want:         []string{"abc"},
		},
		{
			name: "status matched by key when name is empty",
			statuses: []CommitStatus{
				{Key: "build", URL: resultsURL("abc")},
			},
			failingNames: []string{"build"},
			want:         []string{"abc"},
		},
		{
			name: "uppercase UUIDs in URLs are normalized",
			statuses: []CommitStatus{
				{Name: "build", URL: resultsURL("ABC-DEF")},
			},
			failingNames: []string{"build"},
			want:         []string{"abc-def"},
		},
		{
			name: "LatestStatuses dedup happens before UUID collection",
			statuses: []CommitStatus{
				{Name: "build", Key: "build", URL: resultsURL("first")},
				{Name: "build", Key: "build", URL: resultsURL("second")},
			},
			failingNames: []string{"build"},
			want:         []string{"first"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := failedPipelineUUIDs(tt.statuses, tt.failingNames)
			if tt.wantNil {
				if got != nil {
					t.Fatalf("failedPipelineUUIDs = %v, want nil", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("failedPipelineUUIDs = nil, want %v", tt.want)
			}
			keys := make([]string, 0, len(got))
			for k := range got {
				keys = append(keys, k)
			}
			slices.Sort(keys)
			want := slices.Clone(tt.want)
			slices.Sort(want)
			if !slices.Equal(keys, want) {
				t.Fatalf("failedPipelineUUIDs keys = %v, want %v", keys, want)
			}
		})
	}
}
