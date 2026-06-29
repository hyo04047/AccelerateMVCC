#!/usr/bin/env bash
# D-5 newer-fix: ASan + TSan regression for the lineage-walk consult. The walk now builds a per-call
# link table and chases it under the single EBR Guard while the drainer concurrently appends; validate
# no UAF/leak (ASan) and no data race (TSan) on the consult||insert surface + the GC integration tests.
exec > /mnt/c/Users/USER/build_d5_walk_san.log 2>&1
SRC=/mnt/c/Users/USER/projects/AccelerateMVCC
FILTER='Consult.*:ReadViewMirror.*:GcEbrIntegration.*:GcEndToEnd.*:GcSharedDescriptor.*:GcRetireOnce.*'

run_san () {
  local name="$1"; local san="$2"; local B="$HOME/acc-build-$name"
  echo ""; echo "############## $name ##############"
  cmake -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Debug \
        -DCMAKE_CXX_FLAGS="-fsanitize=$san -fno-omit-frame-pointer -g" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=$san" > /mnt/c/Users/USER/d5_walk_${name}_cfg.log 2>&1
  cmake --build "$B" --target test_with_google -j"$(nproc)" > /mnt/c/Users/USER/d5_walk_${name}_build.log 2>&1
  local rc=$?; echo "build rc=$rc"
  if [ $rc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:' /mnt/c/Users/USER/d5_walk_${name}_build.log | head -30; return 1; fi
  local BIN=$(find "$B" -maxdepth 3 -name test_with_google -type f 2>/dev/null | head -1)
  ASAN_OPTIONS=detect_leaks=0 "$BIN" --gtest_filter="$FILTER" 2>&1 | grep -E 'PASSED|FAILED|runtime error|ERROR: |WARNING: ThreadSanitizer|data race|heap-use-after-free|tests from [0-9]' | tail -20
}

run_san asan address
run_san tsan thread
echo ""; echo "=== DONE ==="
