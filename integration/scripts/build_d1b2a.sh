#!/usr/bin/env bash
# Stage D-1b-2a: build + run the standalone MPMC ring stress test under Release/ASan/TSan.
set +e
exec > /mnt/c/Users/USER/build_d1b2a.log 2>&1
SRC=/mnt/c/Users/USER/projects/AccelerateMVCC
JOBS=$(nproc)
run_cfg () {
  local name="$1"; shift; local bdir="$1"; shift; local env="$1"; shift
  echo ""; echo "###### $name ######"
  cmake -S "$SRC" -B "$bdir" "$@" > /tmp/rc_$name.log 2>&1; echo "[$name] cfg rc=$?"
  cmake --build "$bdir" --target accel_ring_test -j"$JOBS" > /tmp/rb_$name.log 2>&1
  local brc=$?; echo "[$name] build rc=$brc"
  if [ $brc -ne 0 ]; then echo "=== BUILD ERR ==="; grep -iE 'error:' /tmp/rb_$name.log | head -20; return; fi
  echo "--- run ---"
  env $env "$bdir/accel_ring_test" 2>&1 | grep -E 'enq=|PASS|FAIL|Sanitizer|data race|runtime error'
}
run_cfg RELEASE "$HOME/acc-build" "" -DCMAKE_BUILD_TYPE=Release
run_cfg ASAN "$HOME/acc-build-asan" "" \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address"
run_cfg TSAN "$HOME/acc-build-tsan" "TSAN_OPTIONS=halt_on_error=0" \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS="-fsanitize=thread -fno-omit-frame-pointer -g" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread"
echo ""; echo "ALL DONE"
