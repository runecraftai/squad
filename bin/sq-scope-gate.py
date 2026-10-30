#!/usr/bin/env python3
"""Report-mode scope gate: compare a brief's declared files with the real diff.

Usage: sq-scope-gate.py <task-id>

Declared entries come from data/<id>/brief.md through the same label rule
bin/sq-plan-validate.sh applies to an execution plan: the `## Execution plan`
section when the brief has one, otherwise the whole brief. Touched files come
from `git diff --name-only <merge-base>..HEAD` in the worktree recorded as
worktree= in state/<id>.meta.

The gate is report-only. It always exits 0, has no strict mode, adds no class
beyond the three below, writes nothing under state/, and appends nothing to any
status file. Callers decide whether anybody acts on the report.

Output, one line per item; only the skip sentinel carries the `scope-gate:`
prefix so a caller can label the rest itself:
  scope-gate: skip (<reason>)          nothing to compare, or a read failed
  declared=<n> touched=<n>             the two sides of the comparison
  planned <path>                       declared and touched
  undeclared <area> (<n>): <paths>     touched outside the plan, grouped by
                                       the two-component directory
  declared_but_untouched <path>        declared and never touched
"""
import fnmatch
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = Path(os.environ.get('SQUAD_BASE', os.environ.get('SQUAD_HOME', ROOT))).resolve()
DATA = Path(os.environ.get('SQUAD_DATA_OVERRIDE', str(BASE / 'data')))
STATE = Path(os.environ.get('SQUAD_STATE_OVERRIDE', str(BASE / 'state')))

TASK_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*')
PLAN_HEADING_RE = re.compile(r'^##\s+[Ee]xecution\s+[Pp]lan\s*$')
HEADING_STOP_RE = re.compile(r'^#{1,2}\s')
LIST_ITEM_RE = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s')
LIST_MARKER_RE = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+')
FILES_LABEL_RE = re.compile(r'^[Ff]iles\s+to\s+touch\b')
OTHER_LABEL_RE = re.compile(
    r'^(?:[Oo]rdered\s+)?[Ss]teps\b'
    r'|^[Aa]cceptance\b'
    r'|^[Vv]erification\b'
    r'|^[Oo]ut\s+of\s+scope\b'
    r'|^[Rr]oll(?:out|back)\b'
    r'|^[Rr]isk\b'
    r'|^[Dd]eliverables?\b'
)
LINE_RANGE_RE = re.compile(r':\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$')
SEGMENT_RE = re.compile(r'[A-Za-z0-9._@+*-]+')
BARE_NAME_RE = re.compile(r'[A-Za-z0-9_-]+\.[A-Za-z0-9]{2,10}$')
BASE_REFS = ('origin/main', 'origin/master', 'main', 'master')


def skip(reason=''):
    print('scope-gate: skip' + (f' ({reason})' if reason else ''))
    return 0


def label_text(line):
    """Normalize a label line the way bin/sq-plan-validate.sh's label rule does."""
    text = line.strip()
    text = text.lstrip('*_')
    return text.rstrip('*_').rstrip()


def inline_label_body(line):
    text = label_text(line)
    if ':' not in text:
        return ''
    return text.split(':', 1)[1].strip()


def is_path_like(text):
    if not text or ' ' in text or '://' in text:
        return False
    if '/' in text:
        return all(SEGMENT_RE.fullmatch(part) for part in text.strip('/').split('/') if part)
    return bool(BARE_NAME_RE.search(text)) and SEGMENT_RE.fullmatch(text) is not None


def clean_candidate(raw, worktree):
    text = raw.strip().strip('`"\'()[]<>,;')
    text = LINE_RANGE_RE.sub('', text)
    text = re.sub(r'#.*$', '', text)
    text = text.rstrip('.,;:')
    while text.startswith('./'):
        text = text[2:]
    prefix = worktree.rstrip('/') + '/'
    if worktree and text.startswith(prefix):
        text = text[len(prefix):]
    return text


def add_candidates(line, entries, worktree, allow_bare):
    for span in re.findall(r'`([^`]+)`', line):
        candidate = clean_candidate(span, worktree)
        if is_path_like(candidate):
            entries.append(candidate)
    if not allow_bare:
        return
    text = re.sub(r'`[^`]+`', ' ', line)
    for word in text.split():
        candidate = clean_candidate(word, worktree)
        if is_path_like(candidate) and candidate not in entries:
            entries.append(candidate)


def is_files_body_stop(line):
    if HEADING_STOP_RE.match(line):
        return True
    text = label_text(line)
    if LIST_ITEM_RE.match(line):
        return OTHER_LABEL_RE.match(label_text(LIST_MARKER_RE.sub('', line))) is not None
    if not text:
        return False
    if OTHER_LABEL_RE.match(text):
        return True
    return text.endswith(':') and len(text) < 80


def entry_head(text):
    """The path-bearing head of one list entry, before its description."""
    return re.split(r'\s+[-\u2013\u2014]\s+|:\s|:$', text)[0]


def execution_plan_lines(lines):
    start = None
    for index, line in enumerate(lines):
        if PLAN_HEADING_RE.match(line):
            start = index + 1
            break
    if start is None:
        return lines
    end = len(lines)
    for index in range(start, len(lines)):
        if HEADING_STOP_RE.match(lines[index]):
            end = index
            break
    return lines[start:end]


def files_entries(lines, worktree):
    label_at = None
    for index, line in enumerate(lines):
        if FILES_LABEL_RE.match(label_text(line)):
            label_at = index
            break
    if label_at is None:
        return False, []
    entries = []
    add_candidates(inline_label_body(lines[label_at]), entries, worktree, allow_bare=True)
    body = []
    for line in lines[label_at + 1:]:
        if is_files_body_stop(line):
            break
        body.append(line)
    items = [line for line in body if LIST_ITEM_RE.match(line)]
    if items:
        for line in items:
            head = entry_head(LIST_MARKER_RE.sub('', line))
            add_candidates(head, entries, worktree, allow_bare=True)
    else:
        # Plain-line shapes carry their paths in backticked spans only, so an
        # adjacent prose sentence cannot become a declared entry.
        for line in body:
            add_candidates(line, entries, worktree, allow_bare=False)
    unique = []
    for entry in entries:
        if entry not in unique:
            unique.append(entry)
    return True, unique


def declared_paths(text, worktree=''):
    """Return (label found, declared entries) for a brief body."""
    lines = text.splitlines()
    region = execution_plan_lines(lines)
    found, entries = files_entries(region, worktree)
    if found or region is lines:
        return found, entries
    return files_entries(lines, worktree)


def meta_value(meta, key):
    for line in meta.read_text(errors='replace').splitlines():
        if line.startswith(f'{key}='):
            return line.split('=', 1)[1].strip()
    return ''


def git(worktree, *args):
    return subprocess.run(
        ['git', '-C', worktree, *args], capture_output=True, text=True, check=False
    )


def touched_paths(worktree):
    """Return (touched paths, skip reason)."""
    refs = []
    head = git(worktree, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    if head.returncode == 0 and head.stdout.strip():
        refs.append(head.stdout.strip())
    refs.extend(BASE_REFS)
    for ref in refs:
        if git(worktree, 'rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}').returncode != 0:
            continue
        merge_base = git(worktree, 'merge-base', 'HEAD', ref)
        if merge_base.returncode != 0 or not merge_base.stdout.strip():
            continue
        diff = git(worktree, 'diff', '--name-only', f'{merge_base.stdout.strip()}..HEAD')
        if diff.returncode != 0:
            return None, f'git diff failed in {worktree}'
        return [line.strip() for line in diff.stdout.splitlines() if line.strip()], ''
    return None, f'no base ref to diff against in {worktree}'


def matches(declared, path):
    if declared.endswith('/'):
        return path.startswith(declared)
    if '*' in declared or '?' in declared:
        return fnmatch.fnmatchcase(path, declared)
    return path == declared


def area_of(path):
    directory = path.split('/')[:-1]
    if not directory:
        return '.'
    return '/'.join(directory[:2])


def report(declared, touched):
    planned = [entry for entry in declared if any(matches(entry, path) for path in touched)]
    untouched = [entry for entry in declared if entry not in planned]
    undeclared = [
        path for path in touched if not any(matches(entry, path) for entry in declared)
    ]
    print(f'declared={len(declared)} touched={len(touched)}')
    for entry in planned:
        print(f'planned {entry}')
    grouped = {}
    for path in undeclared:
        grouped.setdefault(area_of(path), []).append(path)
    for name in sorted(grouped):
        paths = ', '.join(sorted(grouped[name]))
        print(f'undeclared {name} ({len(grouped[name])}): {paths}')
    for entry in untouched:
        print(f'declared_but_untouched {entry}')
    return 0


def run(task):
    brief = DATA / task / 'brief.md'
    if not brief.is_file():
        return skip(f'no brief at {brief}')
    text = brief.read_text(errors='replace')
    found, declared = declared_paths(text)
    if not found:
        return skip()
    if not declared:
        return skip('no path-like entry under Files to touch')

    meta = STATE / f'{task}.meta'
    if not meta.is_file():
        return skip(f'no task meta at {meta}')
    worktree = meta_value(meta, 'worktree')
    if not worktree:
        return skip(f'{meta} records no worktree')
    if not Path(worktree).is_dir():
        return skip(f'worktree is missing: {worktree}')

    touched, reason = touched_paths(worktree)
    if touched is None:
        return skip(reason)
    return report(declared, touched)


def main(argv):
    task = argv[1] if len(argv) > 1 else ''
    if TASK_RE.fullmatch(task) is None:
        return skip('usage: sq-scope-gate.py <task-id>')
    try:
        return run(task)
    except Exception as exc:  # report-only: any surprise is a skip, never a failure
        return skip(str(exc) or exc.__class__.__name__)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
