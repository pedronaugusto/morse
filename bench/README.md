# morse benchmark preparation

Run `./bench/quiet.sh --smoke` from the repository root to build both pinned
revisions and every comparison, check correctness, and execute each workload
once. Smoke samples no benchmark clock and records no timings. On an idle
machine, `./bench/quiet.sh` runs the complete timed pass. `bench/run.sh` is a
compatibility alias. On macOS the entry point prevents sleep during the pass.

Allow **15 minutes per package** in the quiet window; the expected warm-cache
pass is about **1–5 minutes** after smoke preparation, an estimate rather than a measured duration.
Dependency downloads and first compilation can add several minutes. All
builds and correctness checks finish before their timed workload groups.
Results go to `bench/results/<UTC-date>/smoke-<time>.md` + `.json` or
`pass-<time>.md` + `.json`. Both builds and results are ignored by Git.

## Revisions and order

`revisions.json` fixes A (before) at
`ebe7020141cb2b0be92fe692521cc477d7d13ca3`, the last first-parent main commit
before **2026-09-30 00:00:00 +01:00**, and B (after) at
`6f6335eaf5c6bd4b029bcdc37a1d4a0f7968c252`. The midnight cutoff is explicit because Git's
bare `--before=2026-09-30` can inherit the time of day. Refresh the pins and
merge main into bench when main advances; the runner refuses a silently
changed local main. `git archive` extracts exact source snapshots inside
`bench/build/revisions/`, without modifying main or switching worktrees.

The protocol adapter builds unchanged against both public APIs. Each workload
runs **A, B, comparisons, A, B, comparisons …**, five rounds in the timed pass.
A and B receive identical seeded bytes and read sizes. Comparison order is
seeded and shuffled within each round. The original six speed-ceiling tests
also run A, B in each of five rounds, using the same harness at both revisions.
Their original ceilings and correctness assertions are retained. Smoke runs
one iteration per timing loop, with all benchmark clock calls disabled;
its deterministic megabyte byte-count checks are allowed to run fully.
The root `zig build timings -Doptimize=ReleaseFast` remains available on this
branch, but `quiet.sh` owns the complete pass and structured reporting.

## Same-job comparisons

Keep **crossterm 0.29.0, termwiz 0.23.3, and libvaxis 0.6.0** (commit
`173a890d1394946b5d7623c66cd34bcd36d8eeb8`). This compares standalone input
parsing and protocol encoding, not a renderer, terminal emulator, or app.
No new comparison libraries were added. `versions.json`, the Rust manifest
and `Cargo.lock` pin sources and dependencies. Zig is **0.16.0** and Rust is
**1.93.0**. Python **3.12+**, rustup and Unix/macOS are required; `ZIG`,
`RUSTUP`, and `PYTHON` may select executables. Rust toolchains and dependency
caches stay inside the ignored build directory; nothing is installed globally.
Zig uses ReleaseFast, Rust uses cargo release, and compilation uses one job.

- Input: seeded typing/navigation, UTF-8, kitty keyboard modifiers, alternate
  keys, associated text, repeat/release, SGR mouse, bracketed paste, focus,
  OSC colour and clipboard replies. Timed mixed streams use read sizes 1,
  64 and 4096 bytes. Pixel mouse input configures both morse revisions for
  mode 1016; standalone comparison APIs expose coordinates without that flag.
- Output: bold plus RGB/reset, absolute cursor moves, OSC 8 open/close, and
  kitty placement headers. Full passes encode 100,000 seeded operations;
  smoke encodes one. Crossterm has no typed OSC 8/kitty encoder in this
  adapter, so those entries are explicitly unavailable.
- Speed ceilings: style diffs, cursor moves, the private integer encoder and
  formatter, a megabyte of RGBA transmission, mixed input, and the complete
  2-stream × 3-buffer × 4-read-size grid. The private encoder is compiled
  from the selected revision, not from the bench branch's current source.

Native allocation policies remain part of the job. Zig protocol output uses
fixed caller-owned buffers; Rust reuses reserved strings. Processes load inputs
before starting the benchmark clock; parser setup and allocations within a
pass are included. Startup, builds, input loading, correctness, and reporting
are outside the interval. Comparison rates use input bytes or operations;
event/output byte counts remain visible. Speed-budget samples retain native
units and ceilings, including every parser-grid entry.

## Correctness and artifacts

An independent protocol oracle checks both morse revisions against expected
events, for isolated inputs and a shared stream, whole and one-byte chunks.
The encoder subset decoder compares intended terminal state rather than byte
spelling. Smoke currently covers **275 input checks**, encoder checks at each
implementation, and **six speed-budget tests at each package revision**.
`known-differences.json` is the reviewed baseline for comparison libraries;
new, changed, or missing differences fail, as does a morse/oracle mismatch.
No unsupported reports are dropped from the throughput stream. The corpus
is synthetic; no terminal or personal input is captured.

Documented differences include uppercase/alternate-key representation, LF key
policy, absent repeat/reply event variants, text/paste batching, released mouse
button/motion models, split SGR/UTF-8 behavior, and pixel unit metadata. Output
SGR grouping, RGB separators, reset spelling and kitty parameter order may
differ while preserving the checked state. OSC 52 is borrowed base64 in morse
and allocated decoded text in libvaxis; normalization accounts for this.

The JSON includes revisions, harness commit and source hashes, dependency
versions, OS/CPU/memory/power/load information without user or host names,
correctness evidence, execution order, native counts, and raw samples. Markdown
includes the machine record, samples, and (only for a timed pass) paired B/A
medians. Smoke has null time fields and no performance ratios. Additional
internal artifacts are `build/correctness.json` and `build/results.tsv`.
No timing results are committed, and this preparation makes no speed claim.

`python3 bench/src/run.py --check-only` runs the protocol and encoder oracle
against already built tools, then returns before every workload loop.

See [QUIET-PREP.md](QUIET-PREP.md) for the preparation contract and duration estimate.
