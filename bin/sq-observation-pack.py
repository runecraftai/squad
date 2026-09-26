#!/usr/bin/env python3
"""Store, compactly display, and page private task output artifacts."""
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = Path(os.environ.get('SQUAD_BASE', os.environ.get('SQUAD_HOME', ROOT))).resolve()
MIN_BYTES, MAX_BYTES = 16 * 1024, 100 * 1024 * 1024
ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*\Z')


def fail(message, code=2):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def task_id(value):
    if not value or not ID.fullmatch(value):
        fail('invalid task id')
    return value


def atomic(target, payload):
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.observation-', dir=target.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(payload)
        try:
            os.link(temp, target)
        except FileExistsError:
            pass
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def allowed(source, task):
    resolved = source.resolve(strict=True)
    roots = [BASE]
    meta = BASE / 'state' / f'{task}.meta'
    if meta.is_file():
        for line in meta.read_text(errors='replace').splitlines():
            if line.startswith('worktree='):
                roots.append(Path(line.split('=', 1)[1]).resolve())
    if not any(resolved == root or root in resolved.parents for root in roots):
        fail('source outside allowed roots')
    info = resolved.stat()
    if not stat.S_ISREG(info.st_mode) or not MIN_BYTES <= info.st_size <= MAX_BYTES:
        fail('source must be a regular file from 16 KiB to 100 MiB')
    data = resolved.read_bytes()
    if b'\0' in data:
        fail('source contains NUL byte')
    try:
        data.decode('utf-8')
    except UnicodeError:
        fail('source must be UTF-8 text')
    return resolved, data


def artifact(task, digest):
    directory = BASE / 'data' / task / 'artifacts' / 'observations'
    return directory, directory / f'{digest}.raw', directory / f'{digest}.json'


def card_line(line):
    content = line.rstrip(b'\n')
    if len(content) > 64:
        content = content[:61] + b'...'
    return content.decode('utf-8', errors='replace')


def verify(pack):
    if not ID.fullmatch(pack) or len(pack) != 64 or not re.fullmatch('[0-9a-f]{64}', pack):
        fail('invalid pack id', 3)
    matches = []
    for taskdir in (BASE / 'data').glob('*/artifacts/observations'):
        raw, manifest = taskdir / f'{pack}.raw', taskdir / f'{pack}.json'
        if raw.exists() or manifest.exists():
            matches.append((taskdir, raw, manifest))
    if len(matches) != 1:
        fail('pack missing or ambiguous', 3)
    directory, raw, manifest = matches[0]
    try:
        obj = json.loads(manifest.read_text())
        data = raw.read_bytes()
        task = directory.parents[1].name
        lines = data.splitlines(keepends=True)
        if (obj != {'schema_version': 1, 'id': pack, 'task': task, 'sha256': pack,
                    'bytes': len(data), 'lines': len(lines), 'source': 'allowed-file-root'} or
                obj['source'] != 'allowed-file-root' or hashlib.sha256(data).hexdigest() != pack or
                stat.S_IMODE(raw.stat().st_mode) != 0o600 or stat.S_IMODE(manifest.stat().st_mode) != 0o600):
            raise ValueError()
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        fail('pack, hash, or manifest mismatch', 3)
    return obj, data, lines


def main(args):
    if not args:
        fail('usage: create|card|read')
    if args[0] == 'create':
        opts = dict(zip(args[1::2], args[2::2]))
        if len(args) != 5 or set(opts) != {'--task', '--source'}:
            fail('create requires --task ID --source PATH')
        task = task_id(opts['--task'])
        try:
            source, data = allowed(Path(opts['--source']), task)
        except OSError as error:
            fail(f'source unavailable: {error}')
        digest = hashlib.sha256(data).hexdigest()
        directory, raw, manifest = artifact(task, digest)
        atomic(raw, data)
        obj = {'schema_version': 1, 'id': digest, 'task': task, 'sha256': digest,
               'bytes': len(data), 'lines': len(data.splitlines(keepends=True)), 'source': 'allowed-file-root'}
        atomic(manifest, (json.dumps(obj, sort_keys=True, indent=2) + '\n').encode())
        if raw.read_bytes() != data or json.loads(manifest.read_text()) != obj:
            fail('existing pack mismatch', 3)
        print(digest)
    elif args[0] == 'card' and len(args) == 2:
        obj, _, lines = verify(args[1])
        output = [f"id: {obj['id']}\nsha256: {obj['sha256']}\nbytes: {obj['bytes']}\nlines: {obj['lines']}\nfirst 40 lines:"]
        output.extend(card_line(line) for line in lines[:40])
        if len(lines) >= 80:
            output.append('last 40 lines:')
            output.extend(card_line(line) for line in lines[-40:])
        output.append(f"recall: bin/sq-observation-pack.sh read {obj['id']} --offset 1 --limit 200")
        payload = ('\n'.join(output) + '\n').encode()
        sys.stdout.buffer.write(payload)
        metrics = BASE / 'data' / obj['task'] / 'artifacts' / 'observations'
        metrics.mkdir(parents=True, exist_ok=True)
        with (metrics / '.card-metrics.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with (metrics / 'card-bytes.log').open('a') as log:
                os.chmod(log.name, 0o600)
                log.write(f'{len(payload)}\n')
    elif args[0] == 'read':
        if len(args) not in (6, 7):
            fail('read requires PACK --offset N --limit M [--receipt]')
        pack = args[1]
        rest = args[2:]
        receipt = rest[-1] == '--receipt'
        if receipt: rest = rest[:-1]
        if len(rest) != 4 or rest[0] != '--offset' or rest[2] != '--limit': fail('invalid read arguments')
        try: offset, limit = int(rest[1]), int(rest[3])
        except ValueError: fail('invalid offset or limit')
        if offset < 1 or not 1 <= limit <= 200: fail('offset must be >=1 and limit 1..200')
        obj, _, lines = verify(pack)
        if offset > len(lines) + 1: fail('offset beyond end')
        end = min(offset + limit - 1, len(lines))
        selected = lines[offset-1:end]
        for number, line in enumerate(selected, offset):
            sys.stdout.write(f'{number}: {line.decode()}')
            if not line.endswith(b'\n'):
                sys.stdout.write('\n')
        if end < len(lines): print(f'next_offset: {end + 1}')
        if receipt:
            tool = ROOT / 'bin/sq-evidence-receipt.sh'
            result = subprocess.run([str(tool), 'create', '--task', obj['task'], '--source', str(artifact(obj['task'], pack)[1]), '--range', f'{offset}:{end}'], text=True, capture_output=True)
            if result.returncode: fail(result.stderr.strip() or 'receipt creation failed', result.returncode)
            print(f'receipt: {result.stdout.strip().split()[0]}')
    else:
        fail('usage: create --task ID --source PATH | card PACK | read PACK --offset N --limit M [--receipt]')


if __name__ == '__main__': main(sys.argv[1:])
