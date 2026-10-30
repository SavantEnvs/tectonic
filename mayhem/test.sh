#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS tectonic's own cargo test binaries (built by mayhem/build.sh with normal flags):
# the TeX/xdvipdfmx golden-output suites (tests/tex-outputs, tests/formats, tests/bibtex, tests/driver)
# plus the library unit tests. exit 0 = pass.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

LIST="$SRC/target/mayhem-test-bins.txt"
[ -s "$LIST" ] || { echo "ERROR: $LIST missing — mayhem/build.sh builds the test binaries" >&2; emit_ctrf cargo-test 0 1 0; exit 1; }

passed=0; failed=0; skipped=0
while IFS= read -r bin; do
  [ -x "$bin" ] || { echo "ERROR: test binary $bin missing" >&2; failed=$((failed + 1)); continue; }
  echo "=== $bin ==="
  out="$("$bin" --test-threads="$MAYHEM_JOBS" 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -n 15
  line="$(printf '%s\n' "$out" | grep -E '^test result:' | tail -n 1)"
  if [ -z "$line" ]; then
    echo "ERROR: $bin printed no 'test result:' line" >&2; failed=$((failed + 1)); continue
  fi
  p="$(printf '%s' "$line" | sed -nE 's/.* ([0-9]+) passed.*/\1/p')"
  f="$(printf '%s' "$line" | sed -nE 's/.* ([0-9]+) failed.*/\1/p')"
  i="$(printf '%s' "$line" | sed -nE 's/.* ([0-9]+) ignored.*/\1/p')"
  passed=$((passed + ${p:-0})); failed=$((failed + ${f:-0})); skipped=$((skipped + ${i:-0}))
  [ "$rc" -eq 0 ] || [ "${f:-0}" -gt 0 ] || failed=$((failed + 1))
done < "$LIST"

[ "$passed" -gt 0 ] || failed=$((failed + 1))
emit_ctrf cargo-test "$passed" "$failed" "$skipped"
