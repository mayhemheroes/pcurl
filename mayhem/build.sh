#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's go-fuzz harness(es) as sanitized libFuzzer
# binaries (OSS-Fuzz Go path: go-fuzz-build -libfuzzer + clang link). EDIT per repo.
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV (under /opt/toolchains —
# absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the module cache under $GOMODCACHE.
#   - The module cache doubles as a FILE PROXY at $GOMODCACHE/cache/download. We set
#     GOPROXY to that file proxy FIRST, network LAST: the offline re-run resolves
#     entirely from the cache, and the network fallback only fills cache-misses on
#     this first online build. -mod=mod lets go-fuzz-build's `go get` of go-fuzz-dep
#     update go.mod from the cache. (GOPROXY=off is NOT enough — it blocks reading
#     the version list from the cache, which `go get` needs.)
#   - For a FULLY self-contained tree instead: `go mod vendor` and build -mod=vendor.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASan-only for the libFuzzer link (keep ASan regardless of base default).
: "${SANITIZER_FLAGS=-fsanitize=address}"
# DWARF <= 3 contract (SPEC §6.2 item 10): gc emits DWARF4 with no override, so thread
# GO_DEBUG_FLAGS through the cgo shim compiles AND the final clang link, and anchor a
# DWARF3 CU at offset 0 so triage reads DWARF < 4.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} $GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} $GO_DEBUG_FLAGS"
export GO_DEBUG_FLAGS
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# Resolve modules offline-first from the in-image cache; network only as a fallback.
# $(go env GOMODCACHE) reads the pinned ENV, so it is correct under ANY $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

cd "$SRC"
go version

# go-fuzz-build needs the go-fuzz-dep package on the module graph. With -mod=mod +
# the file-proxy GOPROXY this resolves from the cache offline (no-op if already present).
go get github.com/dvyukov/go-fuzz/go-fuzz-dep

# The package dir holding the legacy `func Fuzz(data []byte) int` harness, and
# the output binary name (preserves the old Mayhemfile `target:` for corpus continuity).
HARNESS_DIR="mayhem"
TARGET="pcurl"

mkdir -p "$SRC/mayhem-build"
echo "=== building $TARGET (go-fuzz-build -libfuzzer) ==="
(
  cd "$SRC/$HARNESS_DIR"
  go-fuzz-build -libfuzzer -o "$SRC/mayhem-build/$TARGET.a"
)
# Link the go-fuzz archive into a libFuzzer binary with clang (ASan). A tiny
# -gdwarf-3 anchor object goes FIRST on the link line so the ELF's first
# .debug_info CU is DWARF3 (gc's own CUs are DWARF4).
printf 'int mayhem_dwarf3_anchor;\n' > "$SRC/mayhem-build/anchor.c"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem-build/anchor.c" -o "$SRC/mayhem-build/anchor.o"
$CXX $SANITIZER_FLAGS $GO_DEBUG_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem-build/anchor.o" "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# Build the project's TEST suite too (pre-compiled runner, normal flags) so
# mayhem/test.sh only RUNS it. The root package holds the entire upstream suite.
echo "=== building upstream test runner (go test -c) ==="
go test -c -o "$SRC/mayhem-build/pcurl.test" .
echo "built $SRC/mayhem-build/pcurl.test"
echo "build.sh complete"
