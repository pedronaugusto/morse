#!/usr/bin/env python3
"""Fetch exact sources locally; expose the private crossterm parser only."""
import hashlib
import io
import json
import pathlib
import subprocess
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
V = json.loads((ROOT / 'versions.json').read_text())
DEPS = ROOT / 'build/deps'
DEPS.mkdir(parents=True, exist_ok=True)
name = 'crossterm'
version = V[name]
path = DEPS / f'{name}-{version}'
if not path.exists():
    data = urllib.request.urlopen(f'https://static.crates.io/crates/{name}/{name}-{version}.crate').read()
    if hashlib.sha256(data).hexdigest() != V['crossterm_sha256']:
        raise SystemExit('crossterm archive checksum mismatch')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        archive.extractall(DEPS, filter='data')
if 'bench_parse_event' not in (path / 'src/event.rs').read_text():
    (path / 'src/event.rs').open('a').write('''
// Harness-only visibility shim. Parser implementation is unchanged.
#[cfg(unix)]
pub fn bench_parse_event(bytes: &[u8], more: bool) -> std::io::Result<Option<Event>> {
    sys::unix::parse::parse_event(bytes, more).map(|e| e.and_then(|e| match e {
        InternalEvent::Event(e) => Some(e),
        _ => None,
    }))
}
''')
vaxis = DEPS / 'libvaxis'
if not vaxis.exists():
    subprocess.run(['git', 'clone', '--quiet', 'https://github.com/rockorager/libvaxis.git', str(vaxis)], check=True)
subprocess.run(['git', '-C', str(vaxis), 'fetch', '--quiet', 'origin', V['libvaxis']], check=True)
subprocess.run(['git', '-C', str(vaxis), 'checkout', '--quiet', '--detach', V['libvaxis']], check=True)
assert subprocess.check_output(['git', '-C', str(vaxis), 'rev-parse', 'HEAD'], text=True).strip() == V['libvaxis']
