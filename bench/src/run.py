#!/usr/bin/env python3
"""Correctness first, then in-process throughput (no clock in smoke mode)."""
import argparse
import csv
import json
import os
import pathlib
import random
import subprocess
from generate import generate

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build'
SMOKE = os.environ.get('BENCH_MODE', 'full') == 'smoke'
SIDES = ['morse-before', 'morse', 'crossterm', 'termwiz', 'vaxis']

def invoke(side, task, mode, chunk, data):
    if side in ('morse-before', 'morse', 'vaxis'):
        argv = [str(BUILD / ('before-out/bin/morse-bench' if side == 'morse-before' else f'zig-out/bin/{side}-bench')), task, mode, str(chunk)]
    else:
        argv = [os.environ.get('MORSE_RUST_BENCH', str(BUILD / 'cargo-target/release/terminal-bench')), side, task, mode, str(chunk)]
    return subprocess.check_output(argv, input=data).decode().splitlines()

def classify(case, side, chunk):
    if side in ('morse-before', 'morse'):
        return 'unexpected; investigate morse bug'
    if side == 'termwiz' and chunk == 1 and (case.startswith('mouse') or case == 'pixel_wire'):
        return 'comparison limitation: split SGR mouse prefixes fall back to keys in termwiz InputParser; whole reports parse correctly'
    if case == 'uppercase' and side == 'crossterm':
        return 'model: crossterm infers Shift for uppercase plain text; morse preserves only reported modifiers'
    if case == 'unicode' and side == 'vaxis' and chunk == 1:
        return 'comparison limitation: standalone libvaxis parser emits two replacement characters for a split UTF-8 codepoint'
    if case == 'lf':
        return 'policy: LF is Ctrl+J in vaxis; morse maps LF and CR to Enter; crossterm here uses its default non-raw setting'
    if case.startswith('kitty') and side == 'termwiz':
        return 'coverage/model: termwiz InputParser does not preserve the full kitty event/alternate-key model'
    if case == 'kitty_shift' and side == 'crossterm':
        return 'model: crossterm selects the shifted key, morse retains unshifted key plus alternate codepoint'
    if case == 'kitty_repeat' and side == 'vaxis':
        return 'model: vaxis Event has key_press/key_release, no repeat variant'
    if case.startswith('mouse') and side == 'termwiz':
        return 'model: termwiz mouse reports button state rather than press/release/motion kind'
    if case.startswith('focus') or case.startswith('osc'):
        return 'coverage/model: comparison input parser does not expose this morse event (OSC 52 becomes allocated clipboard text in vaxis)'
    return 'comparison behavior difference; see exact input and events; no morse bug against the protocol oracle'

def output_state(task, hex_line):
    """Independent subset decoder: compare terminal meaning, not byte spelling."""
    import re
    s = bytes.fromhex(hex_line).decode()
    if task == 'cursor':
        match = re.fullmatch(r'\x1b\[(\d+);(\d+)H', s)
        assert match, repr(s)
        return list(map(int, match.groups()))
    if task == 'link':
        # BEL and ST terminate OSC equally.
        s = s.replace('\x07', '\x1b\\')
        assert s == '\x1b]8;;https://example.org/bench\x1b\\\x1b]8;;\x1b\\', repr(s)
        return ['https://example.org/bench', 'closed']
    if task == 'graphics':
        match = re.fullmatch(r'\x1b_G(.*?);?\x1b\\', s)
        assert match, repr(s)
        fields = dict(field.split('=') for field in match[1].rstrip(';').split(','))
        # Omitted q means 0; parameter ordering and optional ; have no effect.
        fields.setdefault('q', '0')
        return fields
    # Track the bold/RGB state before reset and the final reset, retaining
    # every transition. Combined and separate SGR calls have the same meaning.
    state = {'bold': False, 'fg': None}
    saw = None
    for match in re.finditer(r'\x1b\[([0-9;:]*)m', s):
        params = [int(x) for x in match[1].replace(':', ';').split(';') if x] or [0]
        i = 0
        while i < len(params):
            p = params[i]
            if p == 0:
                saw = dict(state); state = {'bold': False, 'fg': None}
            elif p == 1: state['bold'] = True
            elif p == 38:
                assert params[i+1] == 2
                state['fg'] = params[i+2:i+5]; i += 4
            else: raise AssertionError(f'unhandled SGR {params}')
            i += 1
    assert re.sub(r'\x1b\[[0-9;:]*m', '', s) == ''
    return [saw, state]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-only', action='store_true', help='Run the protocol oracle without workload loops')
    args = parser.parse_args()
    generate(SMOKE or args.check_only)
    rows = json.loads((BUILD / 'inputs/cases.json').read_text())
    differences = []
    checks = []
    failures = []
    # Check both whole and fragmented sequences independently of timing.
    for row in rows:
        data = bytes.fromhex(row['hex'])
        for chunk in [1, 64]:
            for side in SIDES:
                records = invoke(side, 'decode', 'check', chunk, data)
                native_count = int(records[-1].split(':')[1])
                events = records[:-1]
                checks.append(dict(side=side, case=row['name'], input=row['hex'], chunk=chunk, native_count=native_count, events=events))
                if events != row['expected']:
                    item = dict(side=side, case=row['name'], chunk=chunk, input=row['hex'], expected=row['expected'], actual=events, reason=classify(row['name'], side, chunk), morse_bug=side in ('morse-before', 'morse'))
                    differences.append(item)
                    if side in ('morse-before', 'morse'): failures.append(item)
    # One stream of shared events verifies framing, ordering and adjacent
    # inputs, not just each parser's isolated-sequence interpretation.
    common = (BUILD / 'inputs/common.bin').read_bytes()
    common_expected = json.loads((BUILD / 'inputs/common_expected.json').read_text())
    for side in SIDES:
        for chunk in [1, 64]:
            records = invoke(side, 'decode', 'check', chunk, common)
            checks.append(dict(side=side, case='common_stream', input=common.hex(), chunk=chunk, native_count=int(records[-1].split(':')[1]), events=records[:-1]))
            if records[:-1] != common_expected:
                differences.append(dict(side=side, case='common_stream', chunk=chunk, input=common.hex(), expected=common_expected, actual=records[:-1], reason=('comparison limitation: split SGR mouse falls back to keys in termwiz InputParser' if side == 'termwiz' else 'comparison limitation: split UTF-8 becomes replacement characters in standalone libvaxis Parser'), morse_bug=side in ('morse-before', 'morse')))
                if side in ('morse-before', 'morse'): failures.append(differences[-1])
    # Pixel mode 1016 has the same SGR bytes as cell mode 1006. Only morse
    # exposes the unit flag in the standalone parser; preserve that difference.
    for side in SIDES:
        records = invoke(side, 'decode_pixels' if side in ('morse-before', 'morse') else 'decode', 'check', 64, bytes.fromhex('1b5b3c303b3634303b3336304d'))
        events = records[:-1]
        expected = ['pixel_mouse:0:640:360:0:press']
        checks.append(dict(side=side, case='pixel_mode', input='1b5b3c303b3634303b3336304d', chunk=64, native_count=int(records[-1].split(':')[1]), events=events))
        if events != expected:
            differences.append(dict(side=side, case='pixel_mode', chunk=64, input='1b5b3c303b3634303b3336304d', expected=expected, actual=events, reason='model: standalone comparison decoder exposes SGR coordinates without a configurable pixel unit flag', morse_bug=side in ('morse-before', 'morse')))
            if side in ('morse-before', 'morse'): failures.append(differences[-1])
    # Validate each encoder's bytes against an independent expected intent.
    output_checks = []
    for task in ['style', 'cursor', 'link', 'graphics']:
        for side in SIDES:
            if side == 'crossterm' and task in ('link', 'graphics'):
                output_checks.append(dict(side=side, task=task, status='unavailable: no typed encoder'))
                continue
            encoded = invoke(side, task, 'check', 64, b'\x2a')[0]
            state = output_state(task, encoded)
            expected = {'cursor': [43, 12], 'link': ['https://example.org/bench', 'closed'], 'graphics': {'a':'p','i':'43','C':'1','q':'0'}, 'style': [{'bold': True, 'fg': [42,100,50]}, {'bold':False,'fg':None}]}[task]
            assert state == expected, (side, task, encoded, state, expected)
            output_checks.append(dict(side=side, task=task, hex=encoded, status='equivalent', state=state))
    (BUILD / 'correctness.json').write_text(json.dumps(dict(checks=checks, differences=differences, output=output_checks), indent=2)+'\n')
    baseline = json.loads((ROOT / 'known-differences.json').read_text())
    observed = {(d['side'], d['case'], d['chunk']): d['actual'] for d in differences if d['side'] != 'morse-before'}
    known = {(d['side'], d['case'], d['chunk']): d['actual'] for d in baseline}
    if observed != known:
        raise SystemExit('correctness differences changed; review build/correctness.json against known-differences.json')
    if failures:
        raise SystemExit('morse differs from protocol oracle; see build/correctness.json')
    if args.check_only:
        print(f'Correctness passed: {len(checks)} input checks; encoder semantics agree; no workloads run')
        return
    r = random.Random(0x4D4F5253)
    output = bytes([42]) if SMOKE else r.randbytes(100_000)
    reps = 1 if SMOKE else 5
    results = []
    for task in ['decode', 'decode_pixels', 'style', 'cursor', 'link', 'graphics']:
        data = (BUILD / 'inputs/mixed.bin').read_bytes() if task == 'decode' else (BUILD / 'inputs/pixels.bin').read_bytes() if task == 'decode_pixels' else output
        for chunk in ([64] if SMOKE or task != 'decode' else [1,64,4096]):
            for rep in range(1, reps+1):
                comparisons = list(SIDES[2:]); r.shuffle(comparisons)
                order = ['morse-before', 'morse'] + comparisons
                for side in order:
                    if side == 'crossterm' and task in ('link', 'graphics'):
                        results.append([side,task,chunk,rep,'unavailable','','','',''])
                        continue
                    lines = invoke(side, 'decode' if task == 'decode_pixels' and side not in ('morse-before', 'morse') else task, 'smoke' if SMOKE else 'full', chunk, data)
                    size,count,ns = map(int, lines[0].split('\t'))
                    assert size == len(data) and count > 0
                    if SMOKE: assert ns == 0
                    rate = '' if SMOKE else f'{size * 1e9 / ns:.3f}'
                    results.append([side,task,chunk,rep,'smoke' if SMOKE else 'measured',size,count,'' if SMOKE else ns,rate])
    with (BUILD / 'results.tsv').open('w') as f:
        writer = csv.writer(f,delimiter='\t',lineterminator='\n')
        writer.writerow(['library','workload','chunk_bytes','iteration','status','input_bytes_or_operations','native_events_or_output_bytes','ns','bytes_or_ops_per_second'])
        writer.writerows(results)
    print(f'{"SMOKE" if SMOKE else "FULL"}: {len(checks)} input cross-checks; {len(differences)} documented comparison differences; output semantics agree; {len(results)} workload rows')
    if SMOKE: print('No clocks sampled; timing columns empty. See build/correctness.json and build/results.tsv.')

if __name__ == '__main__': main()
