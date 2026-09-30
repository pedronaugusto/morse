#!/usr/bin/env python3
"""Synthetic protocol corpus, never captured terminal input."""
import json
import pathlib
import random

ROOT = pathlib.Path(__file__).resolve().parents[1]

def cases():
    r = random.Random(0x4D4F5253)
    x, y = r.randrange(1, 80), r.randrange(1, 24)
    return [
        ('ascii', b'a', ['key:97:0:press']),
        ('uppercase', b'A', ['key:65:0:press']),
        ('unicode', 'λ'.encode(), ['key:955:0:press']),
        ('text', b'hello', [f'key:{c}:0:press' for c in b'hello']),
        ('enter', b'\r', ['key:13:0:press']),
        ('lf', b'\n', ['key:13:0:press']),
        ('tab', b'\t', ['key:9:0:press']),
        ('ctrl_c', b'\x03', ['key:99:4:press']),
        ('up', b'\x1b[A', ['key:57352:0:press']),
        ('alt', b'\x1bx', ['key:120:2:press']),
        ('kitty', b'\x1b[97;5u', ['key:97:4:press']),
        ('kitty_shift', b'\x1b[97:65;2u', ['key:97:1:press']),
        ('kitty_repeat', b'\x1b[97;1:2u', ['key:97:0:repeat']),
        ('kitty_release', b'\x1b[97;1:3u', ['key:97:0:release']),
        ('kitty_text', b'\x1b[97;1;97u', ['key:97:0:press']),
        ('mouse_press', f'\x1b[<0;{x};{y}M'.encode(), [f'mouse:0:{x}:{y}:0:press']),
        ('mouse_release', f'\x1b[<0;{x};{y}m'.encode(), [f'mouse:0:{x}:{y}:0:release']),
        ('mouse_drag', f'\x1b[<32;{x};{y}M'.encode(), [f'mouse:0:{x}:{y}:0:motion']),
        ('mouse_wheel', f'\x1b[<64;{x};{y}M'.encode(), [f'mouse:64:{x}:{y}:0:press']),
        ('pixel_wire', b'\x1b[<0;640;360M', ['mouse:0:640:360:0:press']),
        ('paste', b'\x1b[200~paste text\x1b[201~', ['paste_start'] + [f'key:{c}:0:press' for c in b'paste text'] + ['paste_end']),
        ('focus_in', b'\x1b[I', ['focus_in']),
        ('focus_out', b'\x1b[O', ['focus_out']),
        ('osc_color_bel', b'\x1b]10;rgb:aaaa/bbbb/cccc\x07', ['reply:color:10:170:187:204']),
        ('osc_color_st', b'\x1b]10;rgb:aaaa/bbbb/cccc\x1b\\', ['reply:color:10:170:187:204']),
        ('osc_clipboard', b'\x1b]52;c;c3ludGhldGlj\x1b\\', ['clipboard:synthetic']),
    ]

def generate(smoke):
    out = ROOT / 'build/inputs'
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, data, expected in cases():
        (out / f'{name}.bin').write_bytes(data)
        rows.append(dict(name=name, hex=data.hex(), expected=expected))
    r = random.Random(0x4D4F5253)
    # One shuffled coverage block is the minimum; full mode expands the same
    # distribution to a stream, favouring typing, navigation and small pastes.
    block = [data for _, data, _ in cases()]
    block += [b'editor text ', b'\x1b[A', b'\x1b[C', b'\x1b[97u'] * (1 if smoke else 32)
    r.shuffle(block)
    mixed = b''.join(block) * (1 if smoke else 2048)
    (out / 'mixed.bin').write_bytes(mixed)
    (out / 'pixels.bin').write_bytes(b'\x1b[<0;640;360M' * (1 if smoke else 100_000))
    shared = [row for row in rows if row['name'] in ('ascii','unicode','text','enter','tab','ctrl_c','up','alt','kitty','mouse_press','mouse_wheel','paste')]
    random.Random(0x53484152).shuffle(shared)
    (out / 'common.bin').write_bytes(b''.join(bytes.fromhex(row['hex']) for row in shared))
    (out / 'common_expected.json').write_text(json.dumps([event for row in shared for event in row['expected']]) + '\n')
    (out / 'cases.json').write_text(json.dumps(rows, indent=2) + '\n')
