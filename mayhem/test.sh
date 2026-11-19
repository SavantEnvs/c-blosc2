#!/usr/bin/env bash
#
# mayhem/test.sh — RUN c-blosc2's ENTIRE upstream ctest suite (built by mayhem/build.sh
# into build-tests/; tests/, tests/b2nd/, plugins tests — the full upstream suite).
# Behavioral guard: on top of the ctest exit codes, we assert the cutest runners' printed
# "TEST RESULTS: N tests (N ok, 0 failed)" summaries on a sample of suite binaries, so a
# neutered exit(0) program FAILS here (the summary line disappears).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

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

[ -d build-tests ] || { echo "test.sh: build-tests/ missing — build.sh must build it" >&2; emit_ctrf cmake-ctest 0 1; exit 1; }

# 1) The full upstream suite via ctest.
ctest_log=$(cd build-tests && ctest -j"$MAYHEM_JOBS" 2>&1); ctest_rc=$?
echo "$ctest_log" | tail -15
total=$(echo "$ctest_log" | grep -oP 'tests passed, .* out of \K[0-9]+' | tail -1)
failed=$(echo "$ctest_log" | grep -oP '\K[0-9]+(?= tests failed out of)' | tail -1)
skipped=0
if [ -z "${total:-}" ]; then
  echo "test.sh: could not parse ctest summary (rc=$ctest_rc)" >&2
  emit_ctrf cmake-ctest 0 1; exit 1
fi
failed=${failed:-0}
passed=$(( total - failed ))

# 2) Behavioral guard: the suite runners must PRINT their asserted-results summary
#    ("TEST RESULTS: N tests (N ok, 0 failed)" for cutest, "ALL TESTS PASSED\tTests run: N"
#    for CuTest) — a neutered exit(0) binary prints nothing, so the guard fails.
guard_failed=0
for bin in build-tests/tests/test_compressor build-tests/tests/test_frame build-tests/tests/test_b2nd_roundtrip; do
  if [ -x "$bin" ]; then
    out=$( (cd "$(dirname "$bin")" && "./$(basename "$bin")") 2>&1 ); rc=$?
    line=$(echo "$out" | grep -oP 'TEST RESULTS: \K[0-9]+ tests \([0-9]+ ok, [0-9]+ failed\)|ALL TESTS PASSED\s+Tests run: \K[0-9]+' | tail -1)
    n=$(echo "$line" | grep -oP '^[0-9]+')
    f=$(echo "$line" | grep -oP '[0-9]+(?= failed)' || echo 0)
    if [ "$rc" -eq 0 ] && [ -n "$line" ] && [ "${n:-0}" -gt 0 ] && [ "${f:-1}" -eq 0 ]; then
      echo "guard ok   - $bin: $line"; passed=$(( passed + 1 ))
    else
      echo "guard FAIL - $bin (rc=$rc, summary='${line:-none}')"; guard_failed=$(( guard_failed + 1 ))
    fi
  else
    echo "guard FAIL - $bin missing"; guard_failed=$(( guard_failed + 1 ))
  fi
done
failed=$(( failed + guard_failed ))

emit_ctrf cmake-ctest "$passed" "$failed" "$skipped"
