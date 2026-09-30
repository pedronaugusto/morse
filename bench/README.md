# morse benchmarks

Head-to-head terminal protocol decoding and encoding against crossterm,
termwiz and libvaxis. All inputs are synthetic, from seed `0x4d4f5253`.
No terminal is opened and no personal input is recorded.

From `bench/`, run `BENCH_MODE=smoke ./run.sh` to build and check the smallest
workloads with one iteration. Smoke never reads a benchmark clock and leaves
timing columns empty. Run `./run.sh` on a quiet machine for five iterations
with larger inputs. Do not interpret smoke as performance results.

Use Unix/macOS, Python 3.12+, rustup and Zig 0.16.0. `PYTHON`, `RUSTUP` and
`ZIG` may select tools (including a locally extracted Zig). Rust 1.93.0 is
installed with the minimal profile in `build/rustup`, using the existing
rustup executable; no toolchain is installed globally. Both Zig competitors
must use exactly 0.16.0. Builds use one job each.

Versions and the crossterm source archive SHA-256 are pinned in `versions.json`; Rust direct dependencies are exact
in `src/rust/Cargo.toml` and transitive dependencies in `Cargo.lock`.
Libvaxis is commit `173a890d1394946b5d7623c66cd34bcd36d8eeb8` (0.6.0).
Its own manifest pins zigimg and uucode by commit and package hash. Sources,
Rust toolchains, registries, caches, binaries and results live in the ignored
`build/` directory. Zig 0.16 fetches package sources into the ignored
`zig-pkg/` directory beside the harness manifest. Morse is the repository at `..`;
this branch starts at `af2dc63`. `build/versions.txt` records tool versions.

## Workloads

- Input: shuffled typing and navigation, UTF-8, kitty keyboard modifiers,
  alternate keys, associated text, repeat and release; SGR mouse presses,
  releases, drags and wheel reports; bracketed paste, focus, and OSC colour
  and clipboard replies. Full mode expands the deterministic mixed stream
  and uses read chunks of 1, 64 and 4096 bytes. Smoke uses one coverage block
  and 64-byte chunks. A separate pixel stream exercises mode 1016.
- Output: bold plus RGB foreground and reset; absolute cursor moves; OSC 8
  open/close; kitty image placement headers with varying image IDs and
  cursor preservation. Smoke encodes one operation per workload; full mode
  uses 100,000 seeded operations. No image payload/base64 or terminal I/O is
  included. Missing typed crossterm link/graphics encoders are unavailable.

Zig writes into caller-owned fixed buffers; Rust reuses a reserved String.
Native allocation policies remain part of the measurement. Each process
loads inputs before starting its clock, then times one parser/encoder pass,
including event delivery to a counter and optimization barrier. Process
startup, compilation, input loading and reporting are outside the interval;
parser setup and allocations within the pass are included. No TTY, rendering
or application dispatch is measured. Competitor order is deterministically
shuffled per iteration. Decode rates are input bytes/second, encode rates
are operations/second; native event/output byte counts remain visible.

Crossterm's Unix parser is private. `src/prepare.py` downloads its official
crate and appends only a public visibility shim returning its typed Event;
no parser logic changes. Its normal byte-by-byte accumulation is retained
for every read chunk setting, while morse and termwiz accept chunks and
libvaxis parses successive prefixes. Rust colour output is explicitly
forced on, so inherited NO_COLOR cannot silently remove RGB sequences.
Libvaxis output uses its public ctlseqs templates through Zig's formatter;
this measures those templates, not its whole renderer. Termwiz's KittyImage
formatter emits the header without ST; the adapter appends ST to frame it.

## Correctness and differences

`build/correctness.json` records every input, normalized events, native
counts, differences and output bytes/semantics. Keys use kitty codepoints,
modifier bits and press/repeat/release. Mouse coordinates are normalized to
one based without assuming cells and pixels are interchangeable. Text runs
and combined Paste events expand to the same semantic stream. Colour replies
compare 8-bit RGB values; clipboard replies compare decoded synthetic text.
Isolated cases and a shared mixed stream run with whole and one-byte chunks.
The comparison covers these fields, not every library-specific key metadata
field or every protocol accepted by each package.

`known-differences.json` is the reviewed baseline for pinned rivals. Any new,
changed or missing difference fails the run, as does any morse event that
differs from the corpus's independent expected events. Differences do not
become permission to drop unsupported input from throughput workloads.

| Difference | Assessment |
| --- | --- |
| Crossterm adds Shift to plain uppercase; kitty alternate-key reports select the shifted codepoint and remove Shift | Key representation policy; no morse bug |
| Libvaxis maps LF to Ctrl+J; morse maps CR/LF to Enter | Documented key policy; no morse bug |
| Libvaxis exposes repeat as key_press | Event model has no repeat variant; no morse bug |
| Termwiz lacks kitty alternate keys/event kinds/associated text in InputParser, and focus/OSC replies in that API | Unsupported reports fall back to keys; no morse bug |
| Crossterm lacks OSC reply events | Replies become keys; no morse bug |
| Termwiz mouse model exposes button state, losing the released button and motion kind | Event model difference; no morse bug |
| Termwiz split SGR mouse reports become keys; standalone libvaxis split UTF-8 becomes two replacement characters | Rival parser limitations; no morse bug |
| Standalone rivals expose SGR coordinates without morse's configurable pixel unit flag | Same wire encoding, different mode metadata; no morse bug |
| Morse text batching and rivals' per-key/combined paste delivery change native event counts | Normalized semantic stream agrees where supported; no morse bug |
| SGR grouping/colour separators/reset spelling and kitty parameter order differ | Independent output subset decoder verifies equivalent intended state |

OSC 52 remains borrowed base64 in morse but allocated decoded text in vaxis;
normalization accounts for this. Pixel units cannot be inferred from SGR
bytes alone: the morse adapter sets `mouse_pixels` for the separate workload;
the other standalone APIs lack that configuration. Their coordinate parsing
is still run and their unit metadata difference is reported.

Results are `build/results.tsv`, with raw per-iteration rows and availability;
`build/correctness.json` includes exact synthetic inputs and events, and
`build/versions.txt` identifies the toolchains. No timings are checked in.
