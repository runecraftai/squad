#!/usr/bin/env python3
"""Collect and triage inputs into verifiable backlog candidates.

Phase 1 of the software factory's input half (see data/software-factory-recon
if present, or docs/factory-collect.md for the durable version). This tool
only collects, triages, and queues candidates for human review; it never
dispatches a mission, opens a PR, merges anything, or touches a project.

Usage: sq-factory-collect.py [run] [--config PATH] [--dry-run] [--json]

See docs/factory-collect.md for the config schema, the capability matrix of
sources, and the no-execution boundary.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = Path(os.environ.get('SQUAD_BASE', os.environ.get('SQUAD_HOME', ROOT))).resolve()
DATA = Path(os.environ.get('SQUAD_DATA_OVERRIDE', BASE / 'data'))
STATE_DIR = DATA / 'factory-collect'
SEEN_PATH = STATE_DIR / 'seen.json'
DIGEST_PATH = STATE_DIR / 'digest.md'
DEFAULT_CONFIG = ROOT / '.factory-collect.toml'
TOON_DECODER = ROOT / 'bin' / 'sq-factory-collect-toon.mjs'
SQ_GH = 'sq-gh'
SQ_TASKS = 'sq-tasks'
NODE = 'node'


class SourceError(Exception):
    """A single source failed; the run degrades instead of aborting."""


def sha256_hex(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def run_sq_gh(args):
    try:
        result = subprocess.run([SQ_GH, *args], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SourceError(f'sq-gh unavailable: {error}') from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or '').strip()
        raise SourceError(f"sq-gh {' '.join(args)} failed: {detail}")
    return result.stdout


def decode_toon(text):
    try:
        result = subprocess.run([NODE, str(TOON_DECODER)], input=text, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SourceError(f'toon decoder unavailable: {error}') from error
    if result.returncode != 0:
        raise SourceError(f'toon decode failed: {result.stderr.strip()}')
    try:
        return json.loads(result.stdout or '{}')
    except json.JSONDecodeError as error:
        raise SourceError(f'toon decode produced invalid JSON: {error}') from error


def sq_gh_json(args):
    return decode_toon(run_sq_gh(args))


def load_config(path):
    try:
        with open(path, 'rb') as handle:
            return tomllib.load(handle)
    except OSError as error:
        raise SystemExit(f'cannot read config {path}: {error}')
    except tomllib.TOMLDecodeError as error:
        raise SystemExit(f'invalid config {path}: {error}')


def load_seen(path=SEEN_PATH):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.factory-collect-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def save_seen(seen, path=SEEN_PATH):
    atomic_write(path, json.dumps(seen, sort_keys=True, indent=2) + '\n')


def excerpt_for(body, pattern):
    for line in body.splitlines():
        if pattern.search(line):
            trimmed = line.strip()
            return trimmed[:200] + ('…' if len(trimmed) > 200 else '')
    return body.strip()[:200]


def make_candidate(cand_id, source, fingerprint, link, title, evidence, verifiable_reason, repro):
    return {
        'id': cand_id,
        'source': source,
        'fingerprint': fingerprint,
        'link': link,
        'title': title,
        'evidence': evidence,
        'verifiable_reason': verifiable_reason,
        'repro': repro,
    }


def triage_github_issues(cfg):
    repo = cfg['repo']
    patterns = [re.compile(p) for p in cfg.get('repro_patterns', [])]
    limit = cfg.get('limit', 50)
    state = cfg.get('state', 'open')
    data = sq_gh_json(['issue', 'list', '--state', state, '--limit', str(limit), '--repo', repo, '--fields', 'body,url'])
    candidates, digest = [], []
    for issue in data.get('issues') or []:
        number = issue.get('number')
        body = issue.get('body') or ''
        title = issue.get('title') or f'issue #{number}'
        url = issue.get('url') or f'https://github.com/{repo}/issues/{number}'
        identity = f'issue:{repo}#{number}'
        fingerprint = sha256_hex(identity)
        match = next((p for p in patterns if p.search(body)), None)
        if match is not None:
            candidates.append(make_candidate(
                cand_id=f'fc-issue-{number}',
                source='github_issue',
                fingerprint=fingerprint,
                link=url,
                title=title,
                evidence=excerpt_for(body, match),
                verifiable_reason=f'issue body matches repro signal /{match.pattern}/',
                repro=f'open {url} and follow its named reproduction steps; expect the described bug to occur',
            ))
        else:
            digest.append({
                'id': f'issue-{number}', 'title': title, 'link': url,
                'reason': 'no named reproduction path found in the issue body',
            })
    return candidates, digest


def triage_ci_failures(cfg):
    repo = cfg['repo']
    workflow = cfg.get('workflow')
    branch = cfg.get('branch')
    run_limit = cfg.get('run_limit', 20)
    min_failures = cfg.get('min_failures', 2)
    args = ['run', 'list', '--status', 'failure', '--limit', str(run_limit), '--repo', repo, '--fields', 'url']
    if workflow:
        args += ['--workflow', workflow]
    if branch:
        args += ['--branch', branch]
    data = sq_gh_json(args)
    runs = data.get('runs') or []
    buckets = {}
    for run in runs:
        run_id = run.get('id')
        view = sq_gh_json(['run', 'view', str(run_id), '--repo', repo])
        jobs = view.get('jobs') or []
        failing = [j for j in jobs if (j.get('conclusion') or '').lower() == 'failure']
        if failing:
            for job in failing:
                identity = f"ci:{repo}:{workflow or run.get('workflow')}:{job.get('name')}"
                buckets.setdefault(identity, {'job_name': job.get('name'), 'runs': []})['runs'].append(run)
        else:
            identity = f"ci:{repo}:{workflow or run.get('workflow')}:{branch or run.get('branch')}:(run-level)"
            buckets.setdefault(identity, {'job_name': None, 'runs': []})['runs'].append(run)
    candidates, digest = [], []
    for identity, bucket in buckets.items():
        occurrences = bucket['runs']
        count = len(occurrences)
        latest = occurrences[0]
        job_name = bucket['job_name']
        url = latest.get('url') or f"https://github.com/{repo}/actions/runs/{latest.get('id')}"
        fingerprint = sha256_hex(identity)
        title = latest.get('title') or identity
        if count >= min_failures:
            what_failed = job_name or '(no single job marked failure; run-level failure)'
            candidates.append(make_candidate(
                cand_id=f'fc-ci-{fingerprint[:12]}',
                source='ci_failure',
                fingerprint=fingerprint,
                link=url,
                title=title,
                evidence=f'{what_failed} failed in {count} of the last {len(runs)} fetched runs of {workflow or latest.get("workflow")}',
                verifiable_reason=f'same job/run identity failed at least {min_failures} times across recently fetched runs',
                repro=f"re-run `sq-gh run rerun {latest.get('id')} --failed --repo {repo}`, or open {url}; expect it to pass once fixed",
            ))
        else:
            digest.append({
                'id': f'ci-{fingerprint[:12]}', 'title': title, 'link': url,
                'reason': f'failed {count}/{min_failures} occurrences needed for a stable identity',
            })
    return candidates, digest


SOURCES = {
    'github_issues': triage_github_issues,
    'ci_failures': triage_ci_failures,
}


def dedupe_candidates(candidates, seen):
    """Split candidates into (new, already_seen) using the durable ledger."""
    fresh, dupes = [], []
    for candidate in candidates:
        if candidate['fingerprint'] in seen:
            dupes.append(candidate)
        else:
            fresh.append(candidate)
    return fresh, dupes


def group_digest(digest_by_source):
    lines = ['# Factory collection: human digest (non-qualifying inputs)', '']
    total = 0
    for source, items in digest_by_source.items():
        if not items:
            continue
        lines.append(f'## {source} ({len(items)})')
        for item in items:
            lines.append(f"- [{item['id']}]({item['link']}) {item['title']} — {item['reason']}")
            total += 1
        lines.append('')
    if total == 0:
        lines.append('(nothing to report)')
    return '\n'.join(lines) + '\n', total


def queue_candidate(candidate, repo_tag):
    """Land one fresh candidate in the backlog as a queued (never in-flight) item."""
    body = (
        f"source: {candidate['source']}\n"
        f"link: {candidate['link']}\n"
        f"fingerprint: {candidate['fingerprint']}\n"
        f"verifiable because: {candidate['verifiable_reason']}\n"
        f"evidence: {candidate['evidence']}\n"
        f"to reproduce: {candidate['repro']}\n"
    )
    return sq_tasks_add(candidate['id'], candidate['title'], repo_tag, body)


def sq_tasks_add(cand_id, title, repo_tag, body):
    fd, temp_path = tempfile.mkstemp(prefix='.factory-collect-body-')
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(body)
        result = subprocess.run(
            [SQ_TASKS, 'add', cand_id, title, '--kind', 'candidate', '--repo', repo_tag,
             '--queue', '--body-file', temp_path, '--json'],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SourceError(f'sq-tasks unavailable: {error}') from error
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    if result.returncode != 0:
        raise SourceError(f'sq-tasks add {cand_id} failed: {(result.stderr or result.stdout).strip()}')
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SourceError(f'sq-tasks add {cand_id} returned invalid JSON: {error}') from error


def run_collection(config, dry_run=False, seen=None):
    seen = load_seen() if seen is None else seen
    sources_status = {}
    all_candidates = []
    digest_by_source = {}
    for name, triage in SOURCES.items():
        source_cfg = (config.get('source') or {}).get(name)
        if not source_cfg or not source_cfg.get('enabled', False):
            sources_status[name] = {'ok': True, 'skipped': True}
            continue
        try:
            candidates, digest = triage(source_cfg)
            sources_status[name] = {'ok': True, 'fetched': len(candidates) + len(digest)}
            all_candidates.extend(candidates)
            digest_by_source[name] = digest
        except SourceError as error:
            sources_status[name] = {'ok': False, 'error': str(error)}
        except Exception as error:  # a source must never take the whole run down
            sources_status[name] = {'ok': False, 'error': f'unexpected failure: {error}'}

    fresh, dupes = dedupe_candidates(all_candidates, seen)
    queued = []
    already_in_backlog = []
    if not dry_run:
        for candidate in fresh:
            try:
                result = queue_candidate(candidate, repo_tag='squad')
            except SourceError as error:
                sources_status[candidate['source']] = {
                    **sources_status.get(candidate['source'], {}),
                    'queue_error': str(error),
                }
                continue
            seen[candidate['fingerprint']] = {
                'id': candidate['id'],
                'source': candidate['source'],
                'queued_at': result.get('task', {}).get('created'),
            }
            # sq-tasks add is itself idempotent by id: an `already: true` reply
            # means this exact candidate was already sitting in the backlog
            # (e.g. the local ledger above was lost or reset), so it is a
            # dedupe hit against the backlog, not a freshly queued candidate.
            if result.get('already'):
                already_in_backlog.append(candidate)
            else:
                queued.append(candidate)
        save_seen(seen)

    digest_text, digest_count = group_digest(digest_by_source)
    if not dry_run:
        atomic_write(DIGEST_PATH, digest_text)

    any_enabled = any(not status.get('skipped') for status in sources_status.values())
    all_failed = any_enabled and all(not status.get('ok', False) for status in sources_status.values())

    return {
        'sources': sources_status,
        'candidates_fetched': len(all_candidates),
        'candidates_queued': len(queued) if not dry_run else len(fresh),
        'candidates_already_seen': len(dupes),
        'candidates_already_in_backlog': len(already_in_backlog),
        'digest_count': digest_count,
        'digest': digest_text,
        'queued': queued if not dry_run else fresh,
        'dry_run': dry_run,
        'ok': not all_failed,
    }


def render_summary(result):
    lines = ['Factory collection run:']
    for name, status in result['sources'].items():
        if status.get('skipped'):
            lines.append(f'  {name}: disabled')
        elif status.get('ok'):
            lines.append(f"  {name}: ok ({status.get('fetched', 0)} fetched)")
        else:
            lines.append(f"  {name}: FAILED — {status.get('error')}")
    verb = 'would queue' if result['dry_run'] else 'queued'
    lines.append(f"Candidates {verb}: {result['candidates_queued']}")
    lines.append(f"Candidates already seen (skipped, not re-proposed): {result['candidates_already_seen']}")
    lines.append(f"Candidates already present in the backlog: {result['candidates_already_in_backlog']}")
    lines.append(f"Human digest (non-qualifying): {result['digest_count']} item(s)")
    return '\n'.join(lines)


def main(argv):
    parser = argparse.ArgumentParser(prog='sq-factory-collect', description=__doc__.splitlines()[0])
    parser.add_argument('command', nargs='?', default='run', choices=['run'])
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--dry-run', action='store_true', help='triage without writing the ledger, digest, or backlog')
    parser.add_argument('--json', action='store_true', help='print the full structured result instead of the summary')
    args = parser.parse_args(argv)

    config = load_config(args.config)
    result = run_collection(config, dry_run=args.dry_run)

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(render_summary(result))
        if result['digest_count']:
            print()
            print(result['digest'])
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
