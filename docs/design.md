# Architecture

Morse writes terminal sequences and parses terminal input. The consumer module
uses Zig, its standard library and aegis scalar types: it owns no terminal, executor or event
loop. Writers take caller-owned `std.Io.Writer` storage, and stream parsers retain
partial input in caller-owned buffers. `ci/layers.zig` declares the production
module boundaries. Examples, conformance, test support and measurement belong to
the checkout and are excluded from the fetched consumer's dependency graph.

## Value boundaries

Graphics commands and replies distinguish `ImageId`, `ImageNumber` and
`PlacementId`. Their raw u32 layout and zero sentinels retain the wire format;
`QueryImageId` rejects zero because probes need a correlatable identity.
`GraphicsBytes` distinguishes file sizes and offsets from image dimensions.
`Pixels`, `Cells` and signed `CellOffset` keep image geometry separate from
terminal geometry through command construction to fixed-key serialization.
`PlaceholderPlacement` checks the underline colour's 24-bit range at construction.
Framing and reply/event storage sizes return `ByteCount`; extraction to usize
happens when slicing or asking the allocator for bytes. These types remain in
their existing concern modules, reexported by the root facade. The production
layer graph still points downward, and aegis closes on std.

Borrowed input stays a slice with the caller's lifetime; wrapping it cannot
make storage immutable or extend that lifetime. Parsers validate syntax and
u32 overflow before importing scalar identities. The small graphics-reply
grammar is inline so callers use only the typed result fields they need; the
validated scalar scan remains unchanged. Their bounded inner indices,
base64 chunks and numeric wire encoders retain raw operations with reasons at
the sites: one validated byte domain or a fixed wire field with no mixed-domain
arithmetic. No terminal ownership or future protocol state is introduced.

`ci/preflight.json` selects `ci/glint.json`, which sets A004 (ID, unit and
integer contracts) to gate across production, tests, benchmarks, examples, conformance
and build/CI code. The published preflight pin still executes ziglint; glint G3
accepts these aegis rules only in report mode. The gate configuration is ready
for G4 integration and is not claimed to execute under the current pin.

## Invariants

- `KeyParser` owns no memory: `start <= end <= buffer.len`, the buffer meets
  `min_buffer`, and compaction preserves exactly the unread prefix. Iterators
  advance these bounds; pending reads and public feed/flush/reset use them.
- `Stripper` retains only an incomplete UTF-8 prefix of one to three bytes,
  in text state. Its leading byte determines a longer sequence of at most four
  bytes. Feeding and finishing cannot produce more bytes than their input plus
  the previously retained prefix; finishing restores the initial state.
- Base64 uses a 64-character alphabet and a 256-byte reverse map. Whole groups
  consume three bytes and write four characters. Decoding requires canonical
  padding and writes exactly `decodedLen` bytes, with fewer than eight residual
  bits after each character.
- Capability names and values are even-length ASCII hex, established by the
  reply parser and checked again by the decoder before indexing pairs.
- Placeholder indices fit the protocol's diacritic table; every table entry
  and the placeholder itself is a Unicode scalar, and the table covers every
  possible image-id top byte.
- SGR cost writers discard output without errors. Their counts fit the declared
  maximum sequence size, which also bounds the scratch used for style diffs.
- Escape framing starts on ESC and returns either an incomplete frame or a
  positive prefix length. CSI parameter/intermediate transitions and control
  string terminators are separate grammar states.
- Writers and their cost functions share the same spelling; existing byte,
  round-trip, split-input and fuzz tests check their relationship. Packed
  mouse modes hold two 16-bit settings in 32 bits.

## Measurement

`bench/budgets.zig` owns terminal workload data, names and callbacks only.
The benchmark imports callback selects morse's pinned shakedown module explicitly.
`shakedown.bench` owns the monotonic clock, warmup, calibration, bounded batches,
samples, statistics, JSONL and comparison. Preflight's `Config.bench` owns
ReleaseFast builds, provenance, local smoke execution and interleaved A/B
processes. Hosted CI compiles benchmarks without timing gates. No benchmark
implementation is copied into morse and no source is patched during builds.

Allocation, input construction and exact byte checks precede measurement.
Callbacks reuse buffers and perform complete workload iterations: a style pair,
a cursor move, four integer encodings, one image or a whole input stream. Parser
callbacks initialize their small state for each stream, so repeated samples
start with the same state; that initialization is included in the shared timed
callback. Reads and storage sizes match the previous workload grid. Assertions
about decoded events run before timing. Samples for input rows divide by bytes,
not events, so batching of text does not change their denominator.

Smoke selects a 32×32 RGBA image and 4 KiB streams; measurement selects 512×512
RGBA, 1 MiB mixed input and 128 KiB grid streams. Mixed input ends on whole
protocol pieces. Byte budgets, allocation bounds and cross-buffer event
compatibility remain count-based tests in `src/testing/work_test.zig`.

The formatter is a separate workload with the same four moves. Throughput and
sample summaries come from shakedown. Timing ceilings and derived ratio rows
are removed: neither noisy timings nor comparisons decide correctness. The
shared A/B command requires both revisions to support its public JSONL and
row-selection contract; it does not rewrite an earlier runner.
