#!/usr/bin/env bash
# D-5 C3-c diagnostic: ISOLATE the 64M mode-1 ⑥ collapse -- gen-gate (race) vs real contiguity break.
# The new binary counts gen-gate MISSes as 'gcrace' SEPARATELY from 'noncontig'. Re-run 64M MODE=1 twice:
#   gate ON  (ACCEL_GEN_GATE=1, default): if the MISSes show up as gcrace -> the gen-gate is the cause.
#   gate OFF (ACCEL_GEN_GATE=0): if hit recovers + the deep scan is fast again -> confirms the gen-gate
#                                killed the payoff (a real chain-sever would still MISS as noncontig).
# Lean harness (single deep scan, 30s sleep / 28s churn) to keep the slow gate-ON run short.
exec > /mnt/c/Users/USER/build_d5_c3c_diag.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
echo "=== rebuild mysqld (gen-gate toggle + gcrace counter) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_c3c_diag_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_c3c_diag_build.log | head -40; exit 1; fi

run(){  # $1=gengate(0/1)
  local GG="$1"; local tag="64M_m1_gg${GG}"
  local MLOG=/mnt/c/Users/USER/d5_c3cdiag_${tag}_mysqld.log
  local SLOG=/mnt/c/Users/USER/d5_c3cdiag_${tag}_scan.log
  echo ""; echo "########## 64M MODE=1 ACCEL_GEN_GATE=$GG ##########"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_GEN_GATE=$GG ACCEL_AUDIT_N=1024 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
  Q -e "SELECT COUNT(*) FROM sbtest.sbtest1" >/dev/null
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET profiling=1; SET profiling_history_size=50;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'scan_warm' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
SELECT SLEEP(30);
SELECT 'scan_deep1' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=28 --rand-type=pareto run > /mnt/c/Users/USER/d5_c3cdiag_${tag}_churn.log 2>&1 &
  local CH=$!
  wait $CH; local R1=$(RDS); wait $SNAP; local R2=$(RDS)
  echo "--- scan SUMs ---"; grep -E 'scan_(warm|deep)' "$SLOG"
  echo "--- deep-scan latency (s) ---"; grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_deep'
  echo "PHYSICAL reads during deep scan (R2-R1) = $((R2-R1))"
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] consult + gc ($tag) ---"; grep -E 'consult:|gc: enabled' "$MLOG"
}

run 1     # gen-gate ON: do the MISSes show as gcrace?
run 0     # gen-gate OFF: does hit recover + scan go fast?
echo ""; echo "=== DONE (gate ON gcrace>0 + gate OFF hit recovers => gen-gate is the ⑥ regression cause) ==="
