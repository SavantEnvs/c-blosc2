#!/usr/bin/env bash
#
# mayhem/build.sh — build c-blosc2's fuzz harnesses (sanitized), their standalone
# reproducers, and the upstream ctest suite (normal flags). Runs inside the commit
# image as `mayhem` in /mayhem. This old code vendors every codec in internal-complibs/
# (no FetchContent), so the build needs no network. Build trees live under build/, which
# upstream's .gitignore covers.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

FUZZERS="compress_chunk_fuzzer compress_frame_fuzzer decompress_chunk_fuzzer decompress_frame_fuzzer"

# 1) Sanitized library + libFuzzer harnesses. -fsanitize=fuzzer-no-link puts SanitizerCoverage
#    into the library itself so libFuzzer gets edge feedback (else 0 edges).
cmake -B build/fuzz \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
  -DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_FUZZERS=ON \
  -DBUILD_TESTS=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_EXAMPLES=OFF
cmake --build build/fuzz -j"$MAYHEM_JOBS"
for f in $FUZZERS; do
  cp "build/fuzz/tests/fuzz/$f" "/mayhem/$f"
done

# 2) Standalone (non-fuzzer) run-once reproducers: same harnesses linked against the
#    project's own file-input driver tests/fuzz/standalone.c (used when LIB_FUZZING_ENGINE is unset).
env -u LIB_FUZZING_ENGINE cmake -B build/standalone \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_FUZZERS=ON \
  -DBUILD_TESTS=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_EXAMPLES=OFF
env -u LIB_FUZZING_ENGINE cmake --build build/standalone -j"$MAYHEM_JOBS"
for f in $FUZZERS; do
  cp "build/standalone/tests/fuzz/$f" "/mayhem/$f-standalone"
done

# 3) Upstream test suite, NORMAL flags (independent clean build) — mayhem/test.sh only RUNS it.
cmake -B build/tests \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DBUILD_STATIC=ON -DBUILD_SHARED=ON -DBUILD_TESTS=ON \
  -DBUILD_FUZZERS=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_EXAMPLES=OFF
cmake --build build/tests -j"$MAYHEM_JOBS"
