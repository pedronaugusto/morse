#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
mode=${BENCH_MODE:-full}
case "$mode" in full|smoke) ;; *) echo 'BENCH_MODE must be full or smoke' >&2; exit 2 ;; esac
export BENCH_MODE="$mode"
PYTHON=${PYTHON:-python3}
ZIG=${ZIG:-zig}
RUSTUP=${RUSTUP:-rustup}
zig_version=$($PYTHON -c 'import json; print(json.load(open("versions.json"))["zig"])')
rust_version=$($PYTHON -c 'import json; print(json.load(open("versions.json"))["rust"])')
if [ "$("$ZIG" version)" != "$zig_version" ]; then
    echo "Use Zig $zig_version (ZIG may name a locally extracted binary)" >&2
    exit 2
fi
mkdir -p build/cargo-home build/cargo-target build/rustup build/zig-cache build/zig-global-cache
export CARGO_HOME="$ROOT/build/cargo-home"
export CARGO_TARGET_DIR="$ROOT/build/cargo-target"
export RUSTUP_HOME="$ROOT/build/rustup"
export ZIG_GLOBAL_CACHE_DIR="$ROOT/build/zig-global-cache"
# All toolchain installs and dependency caches are local to this harness.
if ! "$RUSTUP" run "$rust_version" rustc --version > /dev/null 2>&1; then
    "$RUSTUP" toolchain install "$rust_version" --profile minimal --no-self-update
fi
"$PYTHON" src/prepare.py
"$ZIG" build -j1 -Doptimize=ReleaseFast --prefix "$ROOT/build/zig-out" \
    --cache-dir "$ROOT/build/zig-cache" --global-cache-dir "$ROOT/build/zig-global-cache"
"$RUSTUP" run "$rust_version" cargo build -j1 --release --locked --manifest-path src/rust/Cargo.toml
{
    "$ZIG" version
    "$RUSTUP" run "$rust_version" rustc --version
    "$RUSTUP" run "$rust_version" cargo --version
    "$PYTHON" --version
    cat versions.json
} > build/versions.txt
"$PYTHON" src/run.py
