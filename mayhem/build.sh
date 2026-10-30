#!/usr/bin/env bash
#
# mayhem/build.sh — builds (1) the project's own test binaries with normal flags (run by test.sh) and
# (2) the sanitized cargo-fuzz harness from the additive mayhem/fuzz crate, including the instrumented
# C/C++ XeTeX engine. Cargo resolves crates from $CARGO_HOME (/opt/toolchains/rust/cargo); the offline
# PATCH re-run sets CARGO_NET_OFFLINE=true, so `--offline` is deliberately not hard-coded here.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
: "${SRC:=/mayhem}"
: "${CC:=clang}" "${CXX:=clang++}"
export CC CXX
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Zdwarf-version=3}"

cd "$SRC"
unset RUSTFLAGS CFLAGS CXXFLAGS

TEST_FEATURES="external-harfbuzz,serialization"

# ---- (1) test binaries: the project's NORMAL flags, no sanitizers ----------------------------------
echo "=== building the test suite (normal flags) ==="
mkdir -p target
cargo test --no-run --no-default-features --features "$TEST_FEATURES" \
    --test tex-outputs --test formats --test bibtex --test driver \
    --message-format=json > target/mayhem-test-build.json
grep -F '"kind":["test"]' target/mayhem-test-build.json | grep -o '"executable":"[^"]*"' | cut -d'"' -f4 | sort -u > target/mayhem-test-bins.txt
[ -s target/mayhem-test-bins.txt ] || { echo "ERROR: no test executables were built" >&2; exit 1; }

# ---- (2) sanitized fuzz harness --------------------------------------------------------------------
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do FUZZ_TARGETS+=("$(basename "${f%.*}")"); done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

OUT=/tmp/mayhem-build
mkdir -p "$OUT"
LSAN_OBJ=""
if [ -n "$SANITIZER_FLAGS" ]; then
  # LeakSanitizer off at build time: the hook object is linked into every fuzz binary.
  # shellcheck disable=SC2086
  $CC -c $SANITIZER_FLAGS $DEBUG_FLAGS "$SRC/mayhem/lsan_off.c" -o "$OUT/lsan_off.o"
  LSAN_OBJ="$OUT/lsan_off.o"
  # The XeTeX engine and the bridge crates are C/C++: instrument them like the Rust code
  # (ASan+UBSan halting, plus libFuzzer coverage) so the fuzzed engine is sanitized and guided.
  # pointer-overflow, alignment and shift-base are relaxed (benign on x86, and they halt ordinary
  # documents: a zero offset to NULL in dpx-pdfdev.c, a misaligned uint32 store in xetex-ext.c, a
  # left shift of EOF (-1) when reading UTF-16 in xetex-io.c); ASan and the rest of UBSan stay on.
  export CFLAGS="$SANITIZER_FLAGS -fno-sanitize=pointer-overflow,alignment,shift-base -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
  # C++ gets neither coverage nor UBSan: libfuzzer-sys is compiled from C++ with these same flags, a
  # self-instrumented libFuzzer recurses in __sanitizer_cov_trace_const_cmp8 until the stack overflows,
  # and UBSan aborts inside libFuzzer's own FuzzerTracePC.h. The C++ glue keeps ASan.
  export CXXFLAGS="$SANITIZER_FLAGS -fno-sanitize=undefined $DEBUG_FLAGS"
  SAN_RUSTFLAGS="-Zsanitizer=address"
  SAN_ARG=address
  case "$SANITIZER_FLAGS" in
    *undefined*)
      # rustc links with -nodefaultlibs, so the UBSan runtime the instrumented C/C++ needs is added by hand.
      for lib in ubsan_standalone_cxx ubsan_standalone; do
        SAN_RUSTFLAGS="$SAN_RUSTFLAGS -Clink-arg=$($CC --print-file-name=libclang_rt.$lib-x86_64.a)"
      done ;;
  esac
else
  SAN_RUSTFLAGS=""
  SAN_ARG=none
fi
# shellcheck disable=SC2086
export RUSTFLAGS="--cfg fuzzing $SAN_RUSTFLAGS -Cforce-frame-pointers $RUST_DEBUG_FLAGS ${LSAN_OBJ:+-Clink-arg=$LSAN_OBJ}"

echo "=== cargo fuzz build ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "CFLAGS=${CFLAGS:-}"
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" --sanitizer "$SAN_ARG" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "$SRC/$t"
  echo "built $SRC/$t"
done
echo "build.sh complete"
