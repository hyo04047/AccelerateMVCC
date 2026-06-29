#!/usr/bin/env bash
# D-5 newer-fix: standalone regression for the lineage-walk consult. Build Release + run the consult
# tests and the full correctness suite. The Consult.* tests (single-lineage chains, the tie-break case,
# the drainer-lag/interior-drop/no-visible/ineligible/collision/negative-control/concurrency cases) must
# all stay green -- the walk must reproduce them, not just the integration behavior.
exec > /mnt/c/Users/USER/build_d5_walk_std.log 2>&1
SRC=/mnt/c/Users/USER/projects/AccelerateMVCC
B=$HOME/acc-build
echo "=== configure + build (Release) ==="
cmake -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release > /mnt/c/Users/USER/d5_walk_cfg.log 2>&1
cmake --build "$B" --target test_with_google -j"$(nproc)" > /mnt/c/Users/USER/d5_walk_build.log 2>&1
rc=$?; echo "build rc=$rc"
if [ $rc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|error :' /mnt/c/Users/USER/d5_walk_build.log | head -40; exit 1; fi
BIN=$(find "$B" -maxdepth 3 -name test_with_google -type f 2>/dev/null | head -1)
echo "binary: $BIN"
echo "=== Consult.* + ReadViewMirror.* ==="
"$BIN" --gtest_filter='Consult.*:ReadViewMirror.*' 2>&1 | grep -E '^\[|PASSED|FAILED|OK\]' | tail -50
echo "=== full correctness suite ==="
"$BIN" --gtest_filter='MvccVisibility.*:GcDeadzone.*:GcEndToEnd.*:GcEbrIntegration.*:GcSharedDescriptor.*:GcRetireOnce.*:GcBackstopDrain.*:GcFgUnlink.*:GcScale.*:Consult.*:ReadViewMirror.*' 2>&1 | grep -E 'PASSED|FAILED|tests from' | tail -10
echo "=== DONE ==="
