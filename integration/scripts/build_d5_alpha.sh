#!/usr/bin/env bash
# D-5 FG-α MEASUREMENT: does consult cooperative reclaim (ACCEL_CONSULT_FG) actually help the integration read
# path? Workload = a held LLT (old snapshot, pins history) + oltp_read_write at concurrency (recent snapshots).
# The gap between the LLT boundary and the active OLTP views forms in-middle holes (dead versions) that consult's
# Pass-1 map-build must scan. With α ON, consults prune those dead epochs -> shorter chains -> faster Pass-1.
# A/B: same workload, ACCEL_CONSULT_FG=0 vs =1 (GC on both). Compare tps + consult HIT + coop_dead_seen.
exec > /mnt/c/Users/USER/build_d5_alpha_64m.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
echo "=== rebuild mysqld (ACCEL_CONSULT_FG wiring) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_alpha_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_alpha_build.log | head -40; exit 1; fi

run_ab() {  # $1=label(off/on)  $2=ACCEL_CONSULT_FG
  local label="$1"; local fg="$2"; local MLOG=/mnt/c/Users/USER/d5_alpha_${label}.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_GC=1 ACCEL_CONSULT_FG=$fg "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --max-connections=512 --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_read_write $C --tables=4 --table-size=5000 prepare 2>&1 | tail -1
  echo ""; echo "===== RUN consult_fg=$fg ($label) ====="
  # held LLT: an old snapshot pinning history (so chains grow + in-middle holes form), held for the whole run.
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest -e \
      "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; START TRANSACTION WITH CONSISTENT SNAPSHOT; SELECT COUNT(*) FROM sbtest1; SELECT SLEEP(75); COMMIT;" ) >/dev/null 2>&1 &
  local LLT=$!
  sleep 3
  sysbench oltp_read_write $C --tables=4 --table-size=5000 --threads=32 --time=60 --rand-type=uniform run 2>&1 | grep -E 'transactions:|queries:|avg:'
  wait $LLT 2>/dev/null
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null
  for i in $(seq 1 25); do pgrep -f "$MYSQLD" >/dev/null 2>&1 || break; sleep 1; done
  pgrep -f "$MYSQLD" >/dev/null 2>&1 && pkill -9 -f "$MYSQLD" 2>/dev/null
  grep -E '\[accel\] consult:|\[accel\] fg-alpha:|\[accel\] gc: enabled' "$MLOG"
}

echo "=== A/B: held LLT + oltp_read_write 32thr 60s, 64M BP (BG-overwhelmed), GC on; consult_fg off vs on ==="
run_ab off 0
run_ab on  1
echo ""; echo "=== DONE (compare tps; on-run must show coop_dead_seen>0 = alpha engaged) ==="
