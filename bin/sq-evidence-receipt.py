#!/usr/bin/env python3
"""Create and consume private, deterministic evidence receipts."""
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = Path(os.environ.get('SQUAD_BASE', os.environ.get('SQUAD_HOME', ROOT))).resolve()
MAX_SOURCE = 100 * 1024 * 1024

def fail(message, code=2):
    print(message, file=sys.stderr)
    raise SystemExit(code)

def allowed(source, task):
    meta = BASE / 'state' / f'{task}.meta'
    worktree = ''
    if meta.is_file():
        for line in meta.read_text(errors='replace').splitlines():
            if line.startswith('worktree='):
                worktree = line.split('=', 1)[1]
    roots = [BASE]
    if worktree:
        roots.append(Path(worktree).resolve())
    resolved = source.resolve(strict=True)
    if not any(resolved == root or root in resolved.parents for root in roots):
        fail('source outside allowed roots')
    st = resolved.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_SOURCE:
        fail('source must be a regular file no larger than 100 MiB')
    data = resolved.read_bytes()
    if b'\0' in data:
        fail('source contains NUL byte')
    return resolved, data

def validate(receipt):
    try:
        obj = json.loads(Path(receipt).read_text())
        if obj.get('schema_version') != 1 or not isinstance(obj.get('spans'), list):
            raise ValueError()
        source = Path(obj['source'])
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', obj['task']):
            raise ValueError()
        canonical = source.resolve(strict=True)
        meta = BASE / 'state' / f"{obj['task']}.meta"
        worktree = ''
        if meta.is_file():
            for line in meta.read_text(errors='replace').splitlines():
                if line.startswith('worktree='):
                    worktree = line.split('=', 1)[1]
        roots = [BASE] + ([Path(worktree).resolve()] if worktree else [])
        if not any(canonical == root or root in canonical.parents for root in roots):
            raise ValueError()
        st = canonical.stat()
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_SOURCE:
            raise ValueError()
        data = canonical.read_bytes()
        if str(canonical) != obj['source']:
            raise ValueError()
        if hashlib.sha256(data).hexdigest() != obj['sha256'] or len(data) != obj['bytes']:
            return None, 'stale'
        lines = data.splitlines(keepends=True)
        if len(lines) != obj['lines'] or b'\0' in data:
            return None, 'stale'
        total = 0
        for span in obj['spans']:
            start, end = span['range']
            if not (1 <= start <= end <= len(lines)):
                raise ValueError()
            text = b''.join(lines[start-1:end]).decode('utf-8')
            if text != span['text']:
                return None, 'stale'
            total += end-start+1
        if total > 200 or sum(len(s['text'].encode()) for s in obj['spans']) > 32768:
            raise ValueError()
        return obj, None
    except (OSError, KeyError, TypeError, ValueError, UnicodeError, json.JSONDecodeError):
        return None, 'invalid'

def main(args):
    if not args: fail('usage: create|verify|render')
    if args[0] == 'create':
        task = source = None
        ranges = []
        i = 1
        while i < len(args):
            key = args[i]
            if key in ('--task', '--source', '--range') and i+1 < len(args):
                val = args[i+1]; i += 2
                if key == '--task': task = val
                elif key == '--source': source = val
                else: ranges.append(val)
            else: fail(f'unknown or incomplete option: {key}')
        if not task or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', task) or not source or not ranges:
            fail('create requires --task, --source and at least one --range')
        try:
            path, data = allowed(Path(source), task)
        except OSError as e: fail(f'source unavailable: {e}')
        lines = data.splitlines(keepends=True)
        spans, total = [], 0
        for value in ranges:
            m = re.fullmatch(r'([1-9][0-9]*):([1-9][0-9]*)', value)
            if not m: fail(f'invalid range: {value}')
            start, end = map(int, m.groups())
            if end < start or end > len(lines): fail(f'invalid range: {value}')
            if any(not (end < a or start > b) for a,b in [(s['range'][0],s['range'][1]) for s in spans]): fail('overlapping ranges')
            total += end-start+1
            text = b''.join(lines[start-1:end])
            if total > 200 or sum(len(s['text'].encode()) for s in spans)+len(text) > 32768: fail('receipt range limit exceeded')
            try: literal = text.decode('utf-8')
            except UnicodeError: fail('cited lines are not UTF-8')
            spans.append({'range':[start,end], 'text':literal})
        digest = hashlib.sha256(data).hexdigest()
        canonical = str(path)
        identity = hashlib.sha256(json.dumps([canonical,digest,[s['range'] for s in spans]],separators=(',',':')).encode()).hexdigest()
        obj = {'schema_version':1,'id':identity,'task':task,'source':canonical,'sha256':digest,'bytes':len(data),'lines':len(lines),'spans':spans}
        outdir = BASE/'data'/task/'artifacts'/'evidence'
        outdir.mkdir(parents=True, exist_ok=True)
        target = outdir/f'{identity}.json'
        payload = (json.dumps(obj,ensure_ascii=False,sort_keys=True,indent=2)+'\n').encode()
        if target.exists():
            if target.read_bytes() != payload: fail('receipt identity collision')
        else:
            fd,tmp = tempfile.mkstemp(prefix='.receipt-',dir=outdir)
            try:
                os.fchmod(fd,0o600)
                with os.fdopen(fd,'wb') as f: f.write(payload)
                try: os.link(tmp,target)
                except FileExistsError: pass
            finally:
                if os.path.exists(tmp): os.unlink(tmp)
            os.chmod(target,0o600)
        print(f'{identity} {target.relative_to(BASE)}')
    elif args[0] in ('verify','render') and len(args)==2:
        obj, error = validate(args[1])
        if error:
            print(error); raise SystemExit(3)
        if args[0] == 'verify': print('verified')
        else:
            for span in obj['spans']:
                start,end=span['range']
                print(f"source: {obj['source']}\nsha256: {obj['sha256']}\nrange: {start}:{end}")
                print(span['text'],end='' if span['text'].endswith('\n') else '\n')
    else: fail('usage: create --task ID --source PATH --range START:END [--range ...] | verify RECEIPT | render RECEIPT')

if __name__ == '__main__': main(sys.argv[1:])
