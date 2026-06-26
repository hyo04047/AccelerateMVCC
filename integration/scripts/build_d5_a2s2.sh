#!/usr/bin/env bash
# D-5 ⑤a-2 step 2: cuts-driven GC cycle, driven by the pushed InnoDB clock + active-view registry.
# The gc_loop now calls g_accel->run_gc_cycle_from_cuts (-> Epoch_table::garbage_collect_from_cuts),
# building the dead zone from g_view_reg.snapshot (a conservative superset) instead of the standalone
# trx manager. last_boundary is seeded to the first observed boundary (no boot storm). Gated on
# ACCEL_GC=1. serve OFF (shadow consult). Two runs on the SAME prepared data, same binary:
#   A) ACCEL_GC unset  -> GC dormant   (control: enabled=0, retired total=0, behavior unchanged)
#   B) ACCEL_GC=1      -> GC sweeps    (enabled=1, retired total>0, construct_BAD MUST stay 0)
# Headers (epoch_table.h / accelerateMVCC.h) are picked up via -I repo/include; only accel_hook.cc
# is copied into the tree. row0vers.cc left at its current (diag6) patch level.
exec > /mnt/c/Users/USER/build_d5_a2s2.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
rm -f "$INNO/include/active_view_registry.h"   # resolved via -I repo/include

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_a2s2_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_a2s2_build.log | head -40; exit 1; fi

start_mysqld() {  # $1 = extra env prefix (e.g. "ACCEL_GC=1")
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2
  env $1 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$2" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
}
stop_mysqld() {
  t0=$(date +%s); "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null
  for i in $(seq 1 25); do pgrep -f "$MYSQLD" >/dev/null 2>&1 || break; sleep 1; done
  t1=$(date +%s)
  if pgrep -f "$MYSQLD" >/dev/null 2>&1; then echo "  SHUTDOWN HANG (${t0}->${t1})"; pkill -9 -f "$MYSQLD" 2>/dev/null; else echo "  shutdown clean ~$((t1-t0))s"; fi
}

echo "=== init + prepare (once) ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
start_mysqld "" /mnt/c/Users/USER/d5_a2s2_init.log
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
stop_mysqld

echo ""
echo "=== RUN A: GC OFF (control, ACCEL_GC unset) -- 15s oltp_read_write ==="
MLOGA=/mnt/c/Users/USER/d5_a2s2_mysqld_A.log
start_mysqld "" "$MLOGA"
sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=8 --time=15 --rand-type=uniform run 2>&1 | grep -E 'transactions:'
stop_mysqld
grep -E '\[accel\] consult:|\[accel\] gc:' "$MLOGA"

echo ""
echo "=== RUN B: GC ON (ACCEL_GC=1) -- 30s oltp_read_write ==="
MLOGB=/mnt/c/Users/USER/d5_a2s2_mysqld_B.log
start_mysqld "ACCEL_GC=1" "$MLOGB"
sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=uniform run 2>&1 | grep -E 'transactions:'
stop_mysqld
echo "--- [accel] gc progress (mid-run cycles) ---"
grep -E '\[accel\] gc: cycles=' "$MLOGB" | tail -6
echo "--- [accel] final consult + gc (B) ---"
grep -E '\[accel\] consult:|\[accel\] gc: enabled' "$MLOGB"
echo "=== DONE (gate: B enabled=1 retired total>0, construct_BAD=0, shutdown clean; A retired total=0) ==="
