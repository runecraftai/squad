package tui

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/runecraftai/squad/packages/drill/internal/ipc"
	"github.com/runecraftai/squad/packages/drill/internal/types"
)

var ansiRegexp = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(s string) string {
	return ansiRegexp.ReplaceAllString(s, "")
}

// visibleBoxText flattens a rendered box into its visible content, joining
// wrapped lines so assertions follow what a terminal actually displays rather
// than where the renderer happened to break a line.
func visibleBoxText(rendered string) string {
	var lines []string
	for _, line := range strings.Split(rendered, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "│") {
			continue
		}
		line = strings.TrimSuffix(strings.TrimPrefix(line, "│"), "│")
		lines = append(lines, strings.TrimSpace(line))
	}
	return strings.Join(strings.Fields(strings.Join(lines, " ")), " ")
}

// assertRenderedLinesFit proves the renderer never emits a line wider than the
// terminal, which is what would clip text in a real terminal.
func assertRenderedLinesFit(t *testing.T, rendered string, width int) {
	t.Helper()
	for _, line := range strings.Split(rendered, "\n") {
		if got := lipgloss.Width(line); got > width {
			t.Errorf("rendered line is %d columns wide, want <= %d: %q", got, width, stripANSI(line))
		}
	}
}

func ptr[T any](v T) *T { return &v }

func testSocketPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "tui-ipc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "s.sock")
}

func startTestIPCServer(t *testing.T, sock string) *ipc.Server {
	t.Helper()
	srv := ipc.NewServer()
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(sock) }()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		c, err := ipc.Dial(sock)
		if err == nil {
			_ = c.Close()
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	t.Cleanup(func() {
		srv.Close()
		<-errCh
	})
	return srv
}

func testRun() *ipc.RunInfo {
	return &ipc.RunInfo{
		ID:      "run-001",
		RepoID:  "repo-001",
		Branch:  "feature/foo",
		HeadSHA: "abc12345def67890",
		BaseSHA: "000000000000",
		Status:  types.RunRunning,
		Steps: []ipc.StepResultInfo{
			{ID: "s1", StepName: types.StepReview, StepOrder: 1, Status: types.StepStatusPending},
			{ID: "s2", StepName: types.StepTest, StepOrder: 2, Status: types.StepStatusPending},
			{ID: "s3", StepName: types.StepLint, StepOrder: 3, Status: types.StepStatusPending},
			{ID: "s4", StepName: types.StepPush, StepOrder: 4, Status: types.StepStatusPending},
			{ID: "s5", StepName: types.StepPR, StepOrder: 5, Status: types.StepStatusPending},
		},
	}
}
func testRunWithCI() *ipc.RunInfo {
	run := testRun()
	run.Steps = append(run.Steps, ipc.StepResultInfo{
		ID: "s6", StepName: types.StepCI, StepOrder: 6, Status: types.StepStatusPending,
	})
	return run
}
func makeManyFindings(n int) string {
	var items []string
	for i := 1; i <= n; i++ {
		items = append(items, fmt.Sprintf(`{"id":"f%d","severity":"warning","file":"file%d.go","line":%d,"description":"finding %d description"}`, i, i, i, i))
	}
	return fmt.Sprintf(`{"summary":"test summary","items":[%s]}`, strings.Join(items, ","))
}
func boxContentLine(line string) string {
	trimmed := strings.TrimSpace(line)
	if len(trimmed) >= 2 && strings.HasPrefix(trimmed, "│") && strings.HasSuffix(trimmed, "│") {
		inner := trimmed[len("│") : len(trimmed)-len("│")]
		return strings.TrimSpace(inner)
	}
	return ""
}
func visualColumn(line, needle string) int {
	idx := strings.Index(line, needle)
	if idx < 0 {
		return -1
	}
	return lipgloss.Width(line[:idx])
}

func hasLineContainingAll(view string, needles ...string) bool {
	for _, line := range strings.Split(stripANSI(view), "\n") {
		match := true
		for _, needle := range needles {
			if !strings.Contains(line, needle) {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

func hasParallelBoxRow(view string) bool {
	for _, line := range strings.Split(stripANSI(view), "\n") {
		if strings.Count(line, "╭") >= 2 || strings.Count(line, "╯") >= 2 || strings.Count(line, "│") >= 4 {
			return true
		}
	}
	return false
}
