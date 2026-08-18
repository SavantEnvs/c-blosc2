#!/usr/bin/env bash
#
# mayhem/vendor-deps.sh — populate the in-image, offline dependency cache (SPEC §6.5).
#
# c-blosc2 3.x does NOT vendor its codecs any more: upstream's CMake DOWNLOADS lz4, zlib-ng,
# zstd and zfp with FetchContent at configure time, into <builddir>/_deps. Every <builddir>
# is gitignored ("build*" in .gitignore), so rlenv's patch grader — which runs `git clean -ffdX`
# and then rebuilds with NO network (§6.2 item 16, §6.5) — deletes them and the build would
# have to re-fetch. This script runs ONCE, at IMAGE-BUILD time (mayhem/Dockerfile), while the
# network is still available, and stores the pinned tarballs under /opt/toolchains — a fixed,
# $HOME-independent path OUTSIDE /mayhem, so no source-tree clean can reach it. mayhem/build.sh
# then unpacks from that cache and points CMake's BLOSC_*_SOURCE_DIR at the result, so no
# configure step ever touches the network.
#
# Content is pinned by sha256; versions are cross-checked against the BLOSC_*_VERSION defaults
# in CMakeLists.txt, so an upstream codec bump fails the build loudly instead of silently
# downgrading what gets fuzzed.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS_CACHE="${BLOSC_DEPS_CACHE:-/opt/toolchains/c-blosc2-deps}"
MANIFEST="$SRC_DIR/mayhem/deps.txt"

mkdir -p "$DEPS_CACHE"

while read -r name vervar _srcvar ver sha urltmpl; do
  case "${name:-#}" in ''|'#'*) continue ;; esac
  want="$(sed -n "s/^set($vervar \"\([^\"]*\)\".*/\1/p" "$SRC_DIR/CMakeLists.txt" | head -1)"
  if [ -n "$want" ] && [ "$want" != "$ver" ]; then
    echo "vendor-deps.sh: $name version drift — CMakeLists.txt asks for $want, mayhem/deps.txt pins $ver." >&2
    echo "vendor-deps.sh: update the version AND sha256 in mayhem/deps.txt." >&2
    exit 1
  fi
  url="${urltmpl//@V@/$ver}"
  out="$DEPS_CACHE/$name-$ver.tar.gz"
  if [ -f "$out" ] && echo "$sha  $out" | sha256sum -c --status -; then
    echo "vendor-deps.sh: $name $ver already cached"
    continue
  fi
  echo "vendor-deps.sh: fetching $name $ver"
  curl -fsSL --retry 3 --retry-delay 2 -o "$out.tmp" "$url"
  if ! echo "$sha  $out.tmp" | sha256sum -c --status -; then
    echo "vendor-deps.sh: sha256 MISMATCH for $name $ver ($url)" >&2
    echo "vendor-deps.sh: got $(sha256sum < "$out.tmp" | cut -d' ' -f1), expected $sha" >&2
    rm -f "$out.tmp"; exit 1
  fi
  mv "$out.tmp" "$out"
done < "$MANIFEST"

echo "vendor-deps.sh: cache ready at $DEPS_CACHE"
ls -l "$DEPS_CACHE"
