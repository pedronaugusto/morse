#!/usr/bin/env python3
import argparse
import csv
import json
import shutil
import sys
from quiet_support import ROOT, BUILD, PINS, run, tools_setup, snapshots, machine, finish

p = argparse.ArgumentParser(description='Complete morse quiet pass; --smoke never samples benchmark clocks')
p.add_argument('--smoke', action='store_true')
p.add_argument('--check-prepared', action='store_true', help='Verify artifacts without building or measuring')
args = p.parse_args()
sys.path.insert(0, str(ROOT))
from prepared import Prepared
prepared = Prepared(ROOT, BUILD)
if not args.smoke:
    from quiet_support import check_after
    check_after()
    prepared.check()
if args.check_prepared:
    raise SystemExit(0)
zig, rust = tools_setup()
if args.smoke:
    snapshots()
    run([sys.executable, 'src/prepare.py'])
    for side, prefix in [('before', 'before-out'), ('after', 'zig-out')]:
        dest = BUILD / 'revisions' / side
        (dest / 'bench').mkdir(exist_ok=True)
        shutil.copy2(ROOT.parent / 'bench.zig', dest / 'bench.zig')
        shutil.copy2(ROOT / 'budgets.zig', dest / 'bench/budgets.zig')
        for smoke in (False, True):
            run([zig, 'build', '-j1', '-Doptimize=ReleaseFast', '-Dpackage-root=build/revisions/' + side,
                 '-Dsmoke=' + str(smoke).lower(), '--prefix', BUILD / (prefix + ('-smoke' if smoke else ''))])
    run(rust + ['cargo', 'build', '-j1', '--release', '--locked', '--manifest-path', 'src/rust/Cargo.toml'])
    from generate import generate
    generate(False)
    generate(True)
for prefix in ('before-out','zig-out','before-out-smoke','zig-out-smoke'):
    prepared.require(BUILD/prefix/'bin')
prepared.require(BUILD/'cargo-target/release/terminal-bench')
prepared.require(BUILD/'inputs-full')
prepared.require(BUILD/'inputs-smoke')
info = machine(zig, rust)
# run.py checks both package revisions and the established comparison corpus,
# then schedules each workload A, B, comparisons, A, B, comparisons ...
run([sys.executable, 'src/run.py'])
rows = []
with (BUILD / 'results.tsv').open() as f:
    for r in csv.DictReader(f, delimiter='\t'):
        rows.append({'library':r['library'], 'workload':r['workload'], 'chunk_bytes':int(r['chunk_bytes']),
                     'iteration':int(r['iteration']), 'status':r['status'],
                     'units':int(r['input_bytes_or_operations']) if r['input_bytes_or_operations'] else None,
                     'native_count':int(r['native_events_or_output_bytes']) if r['native_events_or_output_bytes'] else None,
                     'ns':int(r['ns']) if r['ns'] else None})
# Preserve the speed-ceiling suite, run identically at each revision. Its
# smoke option takes one pass per loop, retains correctness, and reads no clock.
for rep in range(1, 2 if args.smoke else 6):
    for side, prefix in [('before', 'before-out'), ('after', 'zig-out')]:
        import subprocess
        result = subprocess.run([str(BUILD / (prefix + ('-smoke' if args.smoke else '')) / 'bin/morse-budgets')], capture_output=True, text=True, check=True)
        measurements = []
        for line in result.stderr.splitlines():
            if line.startswith('measurement\t'):
                _, name, value, unit, ceiling = line.split('\t')
                measurements.append({'name': name, 'value':float(value), 'unit':unit, 'ceiling':float(ceiling)})
        for m in measurements:
            rows.append({'library':'morse-before' if side == 'before' else 'morse',
                         'workload':'speed_budget/' + m['name'], 'iteration':rep, 'status':'measured', 'units':1,
                         'ns':m['value'] * (1_000_000 if m['unit'] == 'ms' else 1) if m['unit'] in ('ns','ms','ns/byte') else None,
                         'native_unit':m['unit'], 'value':m['value'], 'ceiling':m['ceiling']})
        rows.append({'library':'morse-before' if side == 'before' else 'morse', 'workload':'speed_ceilings',
                     'iteration':rep, 'status':'smoke' if args.smoke else 'measured', 'units':6,
                     'ns':None, 'measurements':measurements})
correctness = json.loads((BUILD / 'correctness.json').read_text())
correctness['speed_ceilings'] = 'Six tests passed at each revision; smoke loops once without clocks' if args.smoke else 'Six tests and original ceilings passed at each revision'
finish('morse', args.smoke, info, rows, correctness,
       json.loads((ROOT / 'versions.json').read_text()), '3–8 minutes quiet-only; see bench/QUIET-PREP.md for counts and assumptions')

if args.smoke: prepared.write()
