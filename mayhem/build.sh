#!/usr/bin/env bash
#
# mayhem/build.sh — build c-blosc2's fuzz harnesses (sanitized), their standalone
# reproducers, and the upstream ctest suite (normal flags). Runs inside the commit
# image as `mayhem` in /mayhem. The codecs (lz4, zlib-ng, zstd, zfp) come from the
# in-image cache mayhem/vendor-deps.sh populated at image-build time — offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# ---- codecs: restore from the in-image cache, never from the network (SPEC §6.5) ----
# Upstream's CMake pulls lz4/zlib-ng/zstd (and zfp for the plugins) in with FetchContent,
# downloading them into <builddir>/_deps at configure time. ".gitignore" has "build*", so a
# `git clean -ffdX` — which rlenv's patch grader runs before EVERY graded, network-less build
# (§6.2 item 16) — wipes those sources out from under the next configure. So instead of letting
# CMake fetch, we unpack the tarballs mayhem/vendor-deps.sh cached under /opt/toolchains (outside
# /mayhem, therefore untouchable by the clean) into build-deps/ and hand CMake the local checkouts
# via its own BLOSC_*_SOURCE_DIR knobs. build-deps/ is itself gitignored and disposable: this
# restore re-creates it from in-image content on every run, cleaned tree or not.
# FETCHCONTENT_FULLY_DISCONNECTED=ON is the belt-and-braces half — if a future upstream adds a
# fifth FetchContent dependency, configure FAILS here rather than quietly reaching for the network.
DEPS_CACHE="${BLOSC_DEPS_CACHE:-/opt/toolchains/c-blosc2-deps}"
DEPS_DIR="$SRC/build-deps"
DEP_ARGS=(-DFETCHCONTENT_FULLY_DISCONNECTED=ON)
mkdir -p "$DEPS_DIR"
while read -r name vervar srcvar ver sha urltmpl; do
  case "${name:-#}" in ''|'#'*) continue ;; esac
  want="$(sed -n "s/^set($vervar \"\([^\"]*\)\".*/\1/p" "$SRC/CMakeLists.txt" | head -1)"
  if [ -n "$want" ] && [ "$want" != "$ver" ]; then
    echo "build.sh: $name version drift — CMakeLists.txt asks for $want, mayhem/deps.txt pins $ver;" >&2
    echo "build.sh: update the version AND sha256 in mayhem/deps.txt and re-build the image." >&2
    exit 1
  fi
  tarball="$DEPS_CACHE/$name-$ver.tar.gz"
  if [ ! -f "$tarball" ]; then
    echo "build.sh: vendored dependency missing: $tarball" >&2
    echo "build.sh: mayhem/vendor-deps.sh must have run at image-build time (see mayhem/Dockerfile)." >&2
    exit 1
  fi
  if [ ! -d "$DEPS_DIR/$name" ]; then
    rm -rf "$DEPS_DIR/.$name.tmp"
    mkdir -p "$DEPS_DIR/.$name.tmp"
    tar -xzf "$tarball" --strip-components=1 -C "$DEPS_DIR/.$name.tmp"
    mv "$DEPS_DIR/.$name.tmp" "$DEPS_DIR/$name"
  fi
  DEP_ARGS+=("-D$srcvar=$DEPS_DIR/$name")
done < "$SRC/mayhem/deps.txt"
echo "build.sh: codecs from $DEPS_CACHE -> ${DEP_ARGS[*]}"

FUZZERS="compress_chunk_fuzzer compress_frame_fuzzer decompress_chunk_fuzzer decompress_frame_fuzzer"

# 1) Sanitized build of the library + libFuzzer harnesses (tests/fuzz links blosc2_static;
#    LIB_FUZZING_ENGINE in the env makes tests/fuzz/CMakeLists.txt link -fsanitize=fuzzer).
#    -fsanitize=fuzzer-no-link compiles SanitizerCoverage into the library itself so
#    libFuzzer gets edge feedback (without it the target fuzzes blind: 0 edges).
cmake -B build "${DEP_ARGS[@]}" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
  -DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_FUZZERS=ON \
  -DBUILD_TESTS=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_EXAMPLES=OFF
cmake --build build -j"$MAYHEM_JOBS"
for f in $FUZZERS; do
  cp "build/tests/fuzz/$f" "/mayhem/$f"
done

# 2) Standalone (non-fuzzer) run-once reproducers: same harnesses linked against the
#    project's own file-input driver tests/fuzz/standalone.c (built by upstream's CMake
#    when LIB_FUZZING_ENGINE is unset and no FuzzingEngine lib is found).
env -u LIB_FUZZING_ENGINE cmake -B build-standalone "${DEP_ARGS[@]}" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_FUZZERS=ON \
  -DBUILD_TESTS=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_EXAMPLES=OFF
env -u LIB_FUZZING_ENGINE cmake --build build-standalone -j"$MAYHEM_JOBS"
for f in $FUZZERS; do
  cp "build-standalone/tests/fuzz/$f" "/mayhem/$f-standalone"
done

# 3) Upstream test suite, NORMAL flags (independent clean build) — mayhem/test.sh only RUNS it.
cmake -B build-tests "${DEP_ARGS[@]}" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DBUILD_STATIC=ON -DBUILD_SHARED=ON -DBUILD_TESTS=ON -DBUILD_PLUGINS=ON \
  -DBUILD_FUZZERS=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_EXAMPLES=OFF
cmake --build build-tests -j"$MAYHEM_JOBS"
