#!/usr/bin/env bash
# D-5 5-2b C2: turn authoritative serve ON in mode-2 (verify-serve) TOGETHER WITH GC-on.
# mode-2 = vanilla walks the undo chain, byte-compares the cache image to the walked *old_vers, and serves
# the cache record ONLY when they match (construct_BAD counts any cache-HIT mismatch; a mismatch keeps the
# vanilla record). This is the self-verifying safe mode. C2 runs it on oltp_read_write (which exercises
# index update + delete/insert = the cross-generation case) at concurrency, with GC actively reclaiming.
# GATE: construct_BAD == 0 (every SERVED record byte-matched vanilla) AND served>0 AND retire split shows
# BOTH paths (windowed + dummy) ran AND a healthy HIT rate (coverage did not collapse to all-MISS).
exec > /mnt/c/Users/USER/build_d5_c2.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
rm -f "$INNO/include/active_view_registry.h"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_c2_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_c2_build.log | head -40; exit 1; fi

run_one() {  # $1=label  $2=workload  $3=threads  $4=time
  local MLOG=/mnt/c/Users/USER/d5_c2_$1.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2
  ACCEL_AUTHORITATIVE=2 ACCEL_GC=1 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --max-connections=512 --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  echo "--- $1: $2 threads=$3 time=$4 (mode-2 verify-serve + GC) ---"
  sysbench $2 $C --tables=4 --table-size=2000 --threads=$3 --time=$4 --rand-type=uniform run 2>&1 | grep -E 'transactions:'
  t0=$(date +%s); "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null
  for i in $(seq 1 25); do pgrep -f "$MYSQLD" >/dev/null 2>&1 || break; sleep 1; done
  t1=$(date +%s)
  if pgrep -f "$MYSQLD" >/dev/null 2>&1; then echo "  SHUTDOWN HANG"; pkill -9 -f "$MYSQLD" 2>/dev/null; else echo "  shutdown clean ~$((t1-t0))s"; fi
  grep -E '\[accel\] consult:|\[accel\] gc: enabled|\[accel\] view-registry' "$MLOG"
}

pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
# bring up once to create db/user + prepare, then shut down.
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > /mnt/c/Users/USER/d5_c2_init.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=4 --table-size=2000 prepare 2>&1 | tail -1
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 3; pkill -9 -f "$MYSQLD" 2>/dev/null

echo ""
echo "=== C2 mode-2 verify-serve + GC ==="
run_one rw_8   oltp_read_write       8  30
run_one rw_32  oltp_read_write       32 30
run_one upd    oltp_update_non_index 8  20
echo "=== DONE (gate: construct_BAD=0, served>0, retire windowed+dummy>0, clean shutdown) ==="
