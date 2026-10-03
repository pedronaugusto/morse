"""One workload per public operation: records, sizes and comparison coverage.

Each workload is a stream of records (`u32 LE length, bytes`), one call per
record. A writer's record is a seed byte, then its payload; a reader's record
is the reply exactly as a terminal sends it. Both adapters load every record
before the clock starts. Synthetic input only.
"""
import base64
import random
import struct

CT, TW, VX = 'crossterm', 'termwiz', 'vaxis'
ALTS = (CT, TW, VX)

# Reasons an alternative has no call for an operation. Every operation names
# each comparison library: either it runs, or one of these says why not.
NO_CT_CSI = 'crossterm has no command for this sequence'
NO_VX_SEQ = 'libvaxis ctlseqs has no spelling for this sequence'
NO_TW_SEQ = 'termwiz escape types have no variant for this sequence'
NO_PARSE = 'no public parser for this reply'
NO_COST = 'no API counts bytes without writing them'
NO_HELPER = 'no equivalent helper'
CT_FIXED = 'crossterm has commands for named modes only, not a numbered DECSET'
VX_FIXED = 'libvaxis has constants for named modes only, not a numbered DECSET'


def _sized(sizes, make):
    return {name: make(size) for name, size in sizes.items()}


SMALL_TEXT = {'small': 16, 'medium': 256}
BULK = {'small': 16, 'medium': 4096, 'large': 1 << 20}
PIXELS = {'small': 1024, 'medium': 65536, 'large': 1 << 20}
TEXT_SCAN = {'small': 16, 'medium': 1024, 'large': 65536}
COUNTS_CAPS = {'small': 1, 'medium': 8, 'large': 64}
COUNTS_CELLS = {'small': 1, 'medium': 16, 'large': 256}


_ALPHABET = b'abcdefghijklmnopqrstuvwxyz ABCDEFGHIJ0123456789-_./'
_TO_TEXT = bytes(_ALPHABET[i % len(_ALPHABET)] for i in range(256))


def text(r, n, controls=False):
    out = bytearray(r.randbytes(n).translate(_TO_TEXT))
    if controls:
        for i in range(7, n, 61):
            out[i] = r.choice(b'\t\x1b\x07\x7f')
    return bytes(out)


# name: (kind, sizes or None, record maker (r, v, size) -> bytes, alternatives)
# kind 'write' compares bytes; 'read' compares a reduced result line.
def w(alts=None, sizes=None, payload=None):
    alts = alts or {}
    def make(r, v, size):
        return bytes([v]) + (payload(r, v, size) if payload else b'')
    return ('write', sizes, make, alts)


def rd(reply, alts=None, sizes=None):
    return ('read', sizes, lambda r, v, size: reply(r, v, size), alts or {})


def seq_alts(ct=NO_CT_CSI, tw=True, vx=NO_VX_SEQ):
    return {CT: ct, TW: tw, VX: vx}


def b64reply(r, v, size):
    return b'\x1b]52;c;' + base64.b64encode(text(r, size)) + b'\x1b\\'


def caps_reply(r, v, count):
    names = [b'RGB', b'Smulx', b'Setulc', b'Tc', b'Ms', b'Ss', b'Se', b'colors']
    fields = [names[i % 8].hex().encode() + b'=' + str(v + i).encode().hex().encode() for i in range(count)]
    return b'\x1bP1+r' + b';'.join(fields) + b'\x1b\\'


def cursors_reply(r, v, count):
    return b'\x1b[>100;' + b';'.join(f'1:2:{1 + i // 80}:{1 + i % 80}'.encode() for i in range(count)) + b' q'


def csi_sample(r, v, size):
    return [b'\x1b[?25h', f'\x1b[{v + 1};12H'.encode(), f'\x1b[1;38;2;{v};100;50m'.encode(), b'\x1b[5 q'][v % 4]


def control_sample(r, v, size):
    return [f'\x1b]8;id=x{v};https://example.org/bench/{v}\x1b\\'.encode(), f'\x1b_Gi={v + 1};OK\x1b\\'.encode(),
            f'\x1bP>|term({v})\x1b\\'.encode(), b'\x1b]10;rgb:aaaa/bbbb/cccc\x07'][v % 4]


def reply_sample(r, v, size):
    return [f'\x1b[{1 + v % 50};{1 + v}R'.encode(), f'\x1b[?2026;{1 + v % 2}$y'.encode(), b'\x1b[?62;22;52c',
            f'\x1b]11;rgb:{v:02x}{v:02x}/6464/3232\x1b\\'.encode(), f'\x1b_Gi={v + 1};OK\x1b\\'.encode(),
            f'\x1b[?{v % 32}u'.encode(), f'\x1bP>|term({v})\x1b\\'.encode(), f'\x1b[8;{24 + v};{80 + v}t'.encode()][v % 8]


MOUSE = [0, 1, 2, 32, 64]
WRITE_CURSOR = dict(ct=True, tw=True)
OPS = {
    'cursorUp': w(seq_alts(**WRITE_CURSOR)), 'cursorDown': w(seq_alts(**WRITE_CURSOR)),
    'cursorRight': w(seq_alts(ct=True, vx=True)), 'cursorLeft': w(seq_alts(ct=True, vx=True)),
    'cursorNextLine': w(seq_alts(ct=True)), 'cursorPrevLine': w(seq_alts(ct=True)),
    'cursorColumn': w(seq_alts(ct=True)), 'cursorRow': w(seq_alts(ct=True)),
    'cursorSave': w(seq_alts(ct=True)), 'cursorRestore': w(seq_alts(ct=True)),
    'clearLine': w(seq_alts(ct=True)), 'clearScreen': w(seq_alts(ct=True, vx=True)),
    'scrollRegion': w(seq_alts()), 'scrollRegionReset': w(seq_alts(tw='termwiz DECSTBM always spells both margins; no parameterless reset')),
    'scrollUp': w(seq_alts(ct=True)), 'scrollDown': w(seq_alts(ct=True)),
    'insertLines': w(seq_alts()), 'deleteLines': w(seq_alts()), 'insertChars': w(seq_alts()),
    'deleteChars': w(seq_alts()), 'eraseChars': w(seq_alts()), 'repeatChar': w(seq_alts()),
    'resetStyle': w(seq_alts(ct=True, vx=True)),
    'diffStyle': w({CT: 'no public style-diff function', TW: 'no public style-diff function (its renderer diffs internally)', VX: 'no public style-diff function (its renderer diffs internally)'}),
    'applySgr': rd(lambda r, v, s: f'\x1b[1;3;4;38;2;{v};100;50;48;5;{v}m'.encode(),
                   {CT: 'crossterm parses input, not SGR', TW: True, VX: 'libvaxis parses input, not SGR'}),
    'paletteRgb': rd(lambda r, v, s: bytes([v]), {CT: NO_HELPER, TW: 'termwiz palette is a configured table, not the xterm default formula', VX: NO_HELPER}),
    'setMode': w({CT: CT_FIXED, TW: True, VX: VX_FIXED}),
    'altScreen': w(seq_alts(ct=True, vx=True)), 'bracketedPaste': w(seq_alts(ct=True, vx=True)),
    'syncOutput': w(seq_alts(ct=True, vx=True)), 'focusEvents': w(seq_alts(ct=True, vx='libvaxis sets focus reporting only inside its mouse spelling')),
    'cursorVisible': w(seq_alts(ct=True, vx=True)), 'unicodeCore': w(seq_alts(vx=True)),
    'inBandResize': w(seq_alts(vx=True)), 'win32Input': w(seq_alts()),
    'autoWrap': w(seq_alts(ct=True)), 'colorScheme': w(seq_alts(vx=True)),
    'mouse': w(seq_alts(ct='crossterm enables a fixed five-mode set (1000/1002/1003/1015/1006)', vx='libvaxis enables a fixed set that includes focus (1002/1003/1004/1006)')),
    'mouseOff': w(seq_alts(ct='crossterm disables its own fixed five-mode set', vx='libvaxis resets its own fixed set')),
    'kittyKeyboardPush': w(seq_alts(ct=True, vx=True)), 'kittyKeyboardPop': w(seq_alts(ct=True, vx=True)),
    'kittyKeyboardQuery': w(seq_alts(ct='crossterm queries only inside its blocking supports_keyboard_enhancement()', vx=True)),
    'kittyKeyboardSet': w(seq_alts()),
    'modifyKeys': w(seq_alts()), 'modifyKeysReset': w(seq_alts(tw='termwiz XtermKeyMode always spells a resource')), 'queryModifyKeys': w(seq_alts(tw=NO_TW_SEQ)),
    'cursorShape': w(seq_alts(ct=True, vx=True)), 'pointerShape': w(seq_alts(tw=NO_TW_SEQ, vx=True)),
    'pointerShapeReset': w(seq_alts(tw=NO_TW_SEQ, vx='libvaxis names a shape; it has no empty OSC 22 reset')),
    'queryMode': w(seq_alts(vx=True)), 'requestCursorPosition': w(seq_alts(ct='crossterm requests only inside its blocking cursor::position()', vx=True)),
    'requestExtendedCursorPosition': w(seq_alts(tw=NO_TW_SEQ)), 'queryColorScheme': w(seq_alts(tw=NO_TW_SEQ, vx=True)),
    'queryDeviceAttributes': w(seq_alts(vx=True)), 'querySecondaryDeviceAttributes': w(seq_alts()),
    'queryVersion': w(seq_alts(vx=True)),
    'queryColor': w(seq_alts(vx=True)), 'setColor': w(seq_alts(vx=True)), 'resetColor': w(seq_alts(vx=True)),
    'queryPaletteColor': w(seq_alts(vx=True)), 'setPaletteColor': w(seq_alts()), 'resetPaletteColor': w(seq_alts()),
    'resetPalette': w(seq_alts(vx=True)), 'queryWindowSize': w(seq_alts()),
    'resizeTextArea': w(seq_alts(ct=True)),
    'queryCapability': w(seq_alts()),
    'queryCapabilities': w(seq_alts(), COUNTS_CAPS, lambda r, v, n: bytes(n)),
    'transmitImage': w(seq_alts(tw=True), PIXELS, lambda r, v, n: r.randbytes(n)),
    'placeImage': w(seq_alts(ct='crossterm has no typed kitty encoder', vx=True)),
    'deleteImage': w(seq_alts(ct='crossterm has no typed kitty encoder', vx='libvaxis deletes by id only through a live Vaxis instance and tty')),
    'queryGraphics': w(seq_alts(ct='crossterm has no typed kitty encoder', vx='libvaxis queries a fixed id inside its terminal probe')),
    'transmitFrame': w(seq_alts(ct='crossterm has no typed kitty encoder'), PIXELS, lambda r, v, n: r.randbytes(n)),
    'animateImage': w(seq_alts(ct='crossterm has no typed kitty encoder', tw='termwiz KittyImage has no animation-control variant')), 'composeFrames': w(seq_alts(ct='crossterm has no typed kitty encoder')),
    'placeholderRow': w(seq_alts(tw=NO_TW_SEQ)), 'placeholderCell': w(seq_alts(tw=NO_TW_SEQ)),
    'title': w(seq_alts(ct='crossterm SetTitle writes OSC 0 (icon and title), not OSC 2', vx=True), SMALL_TEXT, lambda r, v, n: text(r, n)),
    'iconName': w(seq_alts(), SMALL_TEXT, lambda r, v, n: text(r, n)),
    'titlePush': w(seq_alts()), 'titlePop': w(seq_alts()),
    'workingDirectory': w(seq_alts(vx='libvaxis osc7 formats a parsed std.Uri; morse takes the URI as written'), SMALL_TEXT,
                          lambda r, v, n: b'file://host/' + text(r, n).replace(b' ', b'_')),
    'hyperlink': w(seq_alts(vx=True), SMALL_TEXT, lambda r, v, n: text(r, n)),
    'textSize': w(seq_alts(tw=NO_TW_SEQ, vx=True), {'small': 16}, lambda r, v, n: text(r, n)),
    'promptStart': w(seq_alts()), 'promptEnd': w(seq_alts()), 'commandStart': w(seq_alts()), 'commandEnd': w(seq_alts()),
    'progress': w(seq_alts()),
    'clipboardWrite': w(seq_alts(ct='crossterm CopyToClipboard is behind the osc52 feature, off in this pin', vx=True), BULK, lambda r, v, n: text(r, n)),
    'clipboardRequest': w(seq_alts(vx=True)),
    'notify': w(seq_alts(vx=True), SMALL_TEXT, lambda r, v, n: text(r, n)),
    'notify9': w(seq_alts(vx=True), SMALL_TEXT, lambda r, v, n: text(r, n)),
    'encodeMouse': w(seq_alts(ct='crossterm parses mouse reports; it has no encoder')),
    'extraCursors': w(seq_alts(tw=NO_TW_SEQ, vx='libvaxis spells one cursor per sequence, not a span list'), COUNTS_CELLS, lambda r, v, n: bytes(n)),
    'extraCursorsClear': w(seq_alts(tw=NO_TW_SEQ, vx=True)), 'extraCursorColor': w(seq_alts(tw=NO_TW_SEQ, vx=True)),
    'queryExtraCursorSupport': w(seq_alts(tw=NO_TW_SEQ, vx=True)),
    'queryExtraCursors': w(seq_alts(tw=NO_TW_SEQ)), 'queryExtraCursorColors': w(seq_alts(tw=NO_TW_SEQ)),
    'Probe.write': w({CT: 'crossterm probes one capability at a time inside blocking calls', TW: 'termwiz probes through terminfo and a live terminal', VX: 'libvaxis writes its probe straight to a live tty'}),
    'parseMouse': rd(lambda r, v, s: f'\x1b[<{MOUSE[v % 5]};{1 + v};{1 + v % 50}{"Mm"[v % 2] if MOUSE[v % 5] < 32 else "M"}'.encode(),
                     {CT: True, TW: True, VX: True}),
    'parseMouseX10': rd(lambda r, v, s: b'\x1b[M' + bytes([32 + MOUSE[v % 5], 33 + v % 200, 33 + v % 50]), {CT: True, TW: 'termwiz InputParser reads SGR mouse reports only', VX: True}),
    'parseMouseRxvt': rd(lambda r, v, s: f'\x1b[{32 + MOUSE[v % 5]};{33 + v};{33 + v % 50}M'.encode(), {CT: True, TW: 'termwiz InputParser reads SGR mouse reports only', VX: 'libvaxis reads SGR and X10 mouse reports only'}),
    'toCells': rd(lambda r, v, s: bytes([v]), {CT: NO_HELPER, TW: NO_HELPER, VX: NO_HELPER}),
    'toCellsAt': rd(lambda r, v, s: bytes([v]), {CT: NO_HELPER, TW: NO_HELPER, VX: NO_HELPER}),
    'parseCursorPosition': rd(lambda r, v, s: f'\x1b[{1 + v % 50};{1 + v}R'.encode(), {CT: True, TW: True, VX: True}),
    'parseExtendedCursorPosition': rd(lambda r, v, s: f'\x1b[?{1 + v % 50};{1 + v};1R'.encode(), {CT: NO_PARSE, TW: NO_PARSE, VX: NO_PARSE}),
    'parseModeReply': rd(lambda r, v, s: f'\x1b[?{[1004, 2026, 2027, 2031][v % 4]};{1 + v % 4}$y'.encode(),
                         {CT: NO_PARSE, TW: 'termwiz Parser has no DECRPM report variant', VX: 'libvaxis turns a few set modes into capability flags, dropping the state'}),
    'parseColorSchemeReply': rd(lambda r, v, s: f'\x1b[?997;{1 + v % 2}n'.encode(), {CT: NO_PARSE, TW: NO_PARSE, VX: True}),
    'parseDeviceAttributes': rd(lambda r, v, s: f'\x1b[?62;1;4;6;9;{15 + v % 8};22;52c'.encode(), {CT: 'presence', TW: True, VX: 'presence'}),
    'parseSecondaryDeviceAttributes': rd(lambda r, v, s: f'\x1b[>1;{4000 + v};0c'.encode(), {CT: NO_PARSE, TW: NO_PARSE, VX: NO_PARSE}),
    'parseVersion': rd(lambda r, v, s: f'\x1bP>|term({v})\x1b\\'.encode(), {CT: NO_PARSE, TW: 'termwiz frames the DCS but has no XTVERSION variant', VX: 'libvaxis skips DCS input'}),
    'parseKittyKeyboardReply': rd(lambda r, v, s: f'\x1b[?{v % 32}u'.encode(), {CT: True, TW: True, VX: 'presence'}),
    'parseModifyKeysReply': rd(lambda r, v, s: f'\x1b[>4;{v % 3}m'.encode(), {CT: NO_PARSE, TW: NO_PARSE, VX: NO_PARSE}),
    'parseColorReply': rd(lambda r, v, s: f'\x1b]1{v % 3};rgb:{v:02x}{v:02x}/6464/3232\x1b\\'.encode(), {CT: NO_PARSE, TW: True, VX: True}),
    'parsePaletteReply': rd(lambda r, v, s: f'\x1b]4;{v};rgb:{v:02x}{v:02x}/6464/3232\x1b\\'.encode(), {CT: NO_PARSE, TW: True, VX: True}),
    'parseWindowSize': rd(lambda r, v, s: f'\x1b[8;{24 + v};{80 + v}t'.encode(), {CT: NO_PARSE, TW: True, VX: 'libvaxis reads only in-band resize (CSI 48 t), not size reports'}),
    'parseCapabilityReply': rd(caps_reply, {CT: NO_PARSE, TW: NO_PARSE, VX: NO_PARSE}, COUNTS_CAPS),
    'parseGraphicsResponse': rd(lambda r, v, s: f'\x1b_Gi={v + 1};OK\x1b\\'.encode(), {CT: NO_PARSE, TW: 'termwiz parses kitty commands, not their responses', VX: 'presence'}),
    'parseClipboardReply': rd(b64reply, {CT: 'decodes as it frames; see clipboardReplyDecoded', TW: 'decodes as it frames; see clipboardReplyDecoded', VX: 'decodes as it frames; see clipboardReplyDecoded'}, BULK),
    'clipboardReplyDecoded': rd(b64reply, {CT: NO_PARSE, TW: True, VX: True}, BULK),
    'parseHyperlink': rd(lambda r, v, s: f'\x1b]8;id=x{v};https://example.org/bench/{v}\x1b\\'.encode(), {CT: NO_PARSE, TW: True, VX: NO_PARSE}),
    'parseTextSize': rd(lambda r, v, s: b'\x1b]66;s=2:w=1;' + text(r, 16) + b'\x1b\\', {CT: NO_PARSE, TW: NO_PARSE, VX: NO_PARSE}),
    'parseCsi': rd(csi_sample, {CT: NO_PARSE, TW: True, VX: 'libvaxis frames CSI only inside its input parser'}),
    'parseControlString': rd(control_sample, {CT: NO_PARSE, TW: True, VX: 'libvaxis frames control strings only inside its input parser'}),
    'parseExtraCursorSupport': rd(lambda r, v, s: b'\x1b[>1;2;3;29;30;40;100;101 q', {CT: NO_PARSE, TW: NO_PARSE, VX: 'libvaxis reduces the reply to one capability flag'}),
    'parseExtraCursors': rd(cursors_reply, {CT: NO_PARSE, TW: NO_PARSE, VX: NO_PARSE}, COUNTS_CELLS),
    'parseExtraCursorColors': rd(lambda r, v, s: f'\x1b[>101;30:2:{v}:0:0;40:5:9 q'.encode(), {CT: NO_PARSE, TW: NO_PARSE, VX: NO_PARSE}),
    'Reply.parse': rd(reply_sample, {CT: 'no standalone reply parser', TW: 'no standalone reply parser', VX: 'no standalone reply parser'}),
    'probeMatches': rd(lambda r, v, s: reply_sample(r, v, s) + bytes([v]), {CT: NO_HELPER, TW: NO_HELPER, VX: NO_HELPER}),
    'probeAnswered': rd(reply_sample, {CT: NO_HELPER, TW: NO_HELPER, VX: NO_HELPER}),
    'checkText': rd(lambda r, v, s: bytes([v]) + text(r, s), {CT: NO_HELPER, TW: NO_HELPER, VX: NO_HELPER}, TEXT_SCAN),
    'printable': rd(lambda r, v, s: bytes([v]) + text(r, s, True), {CT: NO_HELPER, TW: NO_HELPER, VX: NO_HELPER}, TEXT_SCAN),
    'KeyEvent.typed': rd(lambda r, v, s: bytes([v]) + ['a', 'é', '👍🏽', 'Z'][v % 4].encode(), {CT: NO_HELPER, TW: NO_HELPER, VX: NO_HELPER}),
    'Event.copy': rd(lambda r, v, s: bytes([v]) + text(r, s), {CT: 'events are owned when parsed', TW: 'events are owned when parsed', VX: 'events borrow; no copy helper'}, TEXT_SCAN),
    'ConsoleDecoder': rd(lambda r, v, s: bytes([v]) + text(r, s), {CT: 'its console decoder is Windows-only; not built on this Mac', TW: 'its console decoder is Windows-only; not built on this Mac', VX: 'its console decoder is Windows-only; not built on this Mac'}, {'small': 16, 'medium': 1024}),
}
for _name in ('diffStyle', 'setStyle', 'resetStyle', 'cursorTo', 'cursorUp', 'cursorDown', 'cursorRight', 'cursorLeft',
              'cursorNextLine', 'cursorPrevLine', 'cursorColumn', 'cursorRow', 'cursorSave', 'cursorRestore', 'clearLine',
              'clearScreen', 'scrollRegion', 'scrollRegionReset', 'scrollUp', 'scrollDown', 'insertLines', 'deleteLines',
              'insertChars', 'deleteChars', 'eraseChars', 'repeatChar', 'setMode', 'hyperlinkStart', 'hyperlinkEnd',
              'hyperlink', 'textSize'):
    OPS['cost.' + _name] = rd(lambda r, v, s: bytes([v]) + text(r, 16), {CT: NO_COST, TW: NO_COST, VX: NO_COST})

# Operations the `before` revision does not have report unavailable at run time.
SKIPPED = {
    'TextError, text_size_max, palette_size, mouse_x10_max, graphics_chunk_bytes, graphics_chunk_base64_max, graphics_placeholder, graphics_placeholder_max': 'constants',
    'Style/Color/Rgb/CursorColor constructors and accessors (ansi, palette, rgb, fromRgb, index, toAnsi, toRgb, eql, rgba)': 'field packing, no measurable cost',
    'Modifiers.bits/fromBits/any, KittyFlags.bits/fromBits, Mouse.Motion.number, Mouse.Encoding.number, PointerShape.name, Clipboard.char/fromChar': 'tiny getters',
    'KeyParser.init/pending/undecided/reset, Events.remainder': 'tiny getters; feed, next and flush are timed in decode',
    'Event.copySize, Reply.copySize, ClipboardReply.decodedLen, DeviceAttributes.list/has, Csi.param, GraphicsResponse.ok, ExtraCursorSupport.any, KeyEvent.text/matches, Probe.asks': 'tiny getters',
    'Rgb16.to8, ConsoleState.reset, ConsoleDecoder.reset': 'tiny value helpers',
}


def records(name, size_name, smoke, check):
    """Records for one workload; `check` gives the few edge records compared across sides."""
    kind, sizes, make, _ = OPS[name]
    size = sizes[size_name] if sizes else None
    r = random.Random(f'{name}/{size_name}')
    if check:
        seeds = list(range(16)) + [37, 99, 254, 255]
        if size and size >= 1 << 16:
            seeds = seeds[:2]
    else:
        count = 1 if smoke else max(8, min(100_000, 2_000_000 // max(1, size or 1)))
        seeds = [r.randrange(256) for _ in range(count)]
    out = bytearray()
    for v in seeds:
        rec = make(r, v, size)
        out += struct.pack('<I', len(rec)) + rec
    return bytes(out)


def workloads():
    for name, (kind, sizes, _, _) in OPS.items():
        for size_name in (sizes or {None: None}):
            yield name, size_name


# ---------------------------------------------------------------- equivalence
# An independent subset decoder for written sequences: two spellings agree
# when a terminal reads the same thing from them. ECMA-48 defaults count as
# written (CSI A = CSI 1 A), BEL and ST end an OSC alike, colour specs compare
# by their 8-bit value, kitty keys compare unordered with protocol defaults
# dropped, and XTGETTCAP hex compares case-insensitively.
import re

_DEFAULT_ONE = set('ABCDEFGISTLMPX@Zbd`ae')
_DEFAULT_ZERO = set('JKm')
# Kitty pop takes a count (default 1); XTVERSION a zero.
_PREFIXED_DEFAULTS = {('<', 'u'): '1', ('>', 'q'): '0'}
_KITTY_DEFAULTS = {('q', '0'), ('C', '0'), ('m', '0'), ('t', 'd'), ('f', '32'), ('a', 't'), ('o', ''), ('d', 'a')}


def _scale(hexdigits):
    return round(int(hexdigits, 16) * 255 / (16 ** len(hexdigits) - 1))


def _colors(body):
    body = re.sub(r'rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})',
                  lambda m: 'rgb8:%d/%d/%d' % tuple(_scale(g) for g in m.groups()), body)
    return re.sub(r'#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})\b',
                  lambda m: 'rgb8:%d/%d/%d' % tuple(int(g, 16) for g in m.groups()), body)


def semantic(data):
    out, i, text = [], 0, bytearray()
    def flush():
        if text:
            out.append(('TEXT', bytes(text)))
            text.clear()
    while i < len(data):
        if data[i] != 0x1b or i + 1 >= len(data):
            text.append(data[i]); i += 1; continue
        flush()
        c = chr(data[i + 1])
        if c == '[':
            j = i + 2
            while not 0x40 <= data[j] <= 0x7e:
                j += 1
            m = re.fullmatch(r'([<=>?]?)([0-9;:]*)([ -/]*)', data[i + 2:j].decode('latin1'))
            prefix, params, inter = m.groups()
            final = chr(data[j])
            ps = params.split(';') if params else []
            default = ('1' if (final in _DEFAULT_ONE or final in 'Hf') and not prefix else
                       '0' if final in _DEFAULT_ZERO and not prefix else _PREFIXED_DEFAULTS.get((prefix, final)))
            if default is not None:
                ps = [p or default for p in ps]
                while ps and ps[-1] == default:
                    ps.pop()
            out.append(('CSI', prefix, tuple(ps), inter, final))
            i = j + 1
        elif c in ']_P':
            j = i + 2
            while not (data[j] == 7 or (data[j] == 0x1b and data[j + 1] == ord('\\'))):
                j += 1
            body = data[i + 2:j].decode('latin1')
            i = j + (1 if data[j] == 7 else 2)
            if c == ']':
                # OSC 110-112 take no parameter; a bare trailing `;` is read the same.
                out.append(('OSC', _colors(re.sub(r'^(\d+);$', r'\1', body))))
            elif c == '_' and body.startswith('G'):
                keys, _, payload = body[1:].partition(';')
                fields = {tuple(kv.split('=', 1)) for kv in keys.split(',') if kv}
                out.append(('APC', tuple(sorted(fields - _KITTY_DEFAULTS)), payload))
            else:
                out.append(('DCS' if c == 'P' else 'APC', body.lower()))
        else:
            out.append(('ESC', c))
            i += 2
    flush()
    return out


# Where a comparison reports less than morse, both sides are reduced to what
# the comparison reports before they are compared. The label goes with the row.
PROJECTIONS = {
    ('parseMouse', TW): (lambda line: ':'.join(line.split(':')[2:5]),
                         'termwiz reports held-button state, not which button changed or press/release; compared on x:y:modifiers'),
    ('parseCsi', TW): (lambda line: 'csi', 'termwiz types every CSI into an enum; morse frames it; compared on framing only'),
    ('parseControlString', TW): (lambda line: line.split('|')[0],
                                 'termwiz types each OSC/APC/DCS; morse frames it; compared on the introducer'),
}
PRESENCE_LABEL = 'reports only that the reply arrived; compared on presence'

# Reviewed differences: the record's bytes differ in meaning, with the reason.
KNOWN = {
    ('kittyKeyboardPush', TW): 'termwiz appends a mode parameter (CSI > flags ; 1 u) that push does not take',
    ('transmitImage/medium', TW): 'termwiz writes one unchunked APC; kitty caps a direct chunk at 4096 base64 bytes, morse splits',
    ('transmitImage/large', TW): 'termwiz writes one unchunked APC; kitty caps a direct chunk at 4096 base64 bytes, morse splits',
    ('transmitFrame/medium', TW): 'termwiz writes one unchunked APC; kitty caps a direct chunk at 4096 base64 bytes, morse splits',
    ('transmitFrame/large', TW): 'termwiz writes one unchunked APC; kitty caps a direct chunk at 4096 base64 bytes, morse splits',
    ('parseMouseRxvt', CT): 'crossterm leaves the 32 bias on rxvt (1015) coordinates; xterm adds 1+32 to each',
    ('parseKittyKeyboardReply', CT): 'crossterm reads one digit of the flags, so 10-31 come back wrong',
}
