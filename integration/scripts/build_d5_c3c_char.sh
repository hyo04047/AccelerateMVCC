#!/usr/bin/env bash
# D-5 C3-c characterization: quantify the ⑥ payoff vs the GC chain-sever degradation under a held reader +
# concurrent churn at small BP, with the SHIPPED mode-1 consult (live-chain walk + 5b-lite + gen-gate). Run
# the SAME lean ⑥ scenario N times (fixed config) and record, per run: deep-scan latency, consult HIT vs
# chase_break MISS, the noncontig split, construct_BAD (must be 0 EVERY run = always correct), and GC retire
# volume (the variable that decides hold-vs-degrade). Output is the honest distribution: how often the cache
# holds the fast read vs degrades to the correct walk, and that it NEVER serves a wrong row.
exec > /mnt/c/Users/USER/build_d5_c3c_char.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run(){  # $1=iteration
  local it="$1"; local MLOG=/mnt/c/Users/USER/d5_c3cchar_${it}_mysqld.log; local SLOG=/mnt/c/Users/USER/d5_c3cchar_${it}_scan.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_AUDIT_N=1024 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1 >/dev/null
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
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=28 --rand-type=pareto run > /mnt/c/Users/USER/d5_c3cchar_${it}_churn.log 2>&1 &
  local CH=$!
  wait $CH; wait $SNAP
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_deep1' | awk '{print $2}' | head -1)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | head -1)
  local SPLIT=$(grep -E 'noncontig split' "$MLOG" | head -1)
  local GC=$(grep -E '\[accel\] gc: enabled' "$MLOG" | head -1)
  echo "RUN $it: deep1_latency=${LAT}s"
  echo "  $CONS"
  echo "  $SPLIT"
  echo "  $GC"
}

echo "=== ⑥ characterization: held reader + 8-thread churn, 64M BP, mode-1+GC (SHIPPED consult), 4 runs ==="
echo "=== gate: construct_BAD=0 EVERY run (always correct); latency hold (~fast) vs degrade (~walk) with GC volume ==="
for it in 1 2 3 4; do run $it; done
echo ""; echo "=== DONE (read: latency distribution + construct_BAD=0 across all runs) ==="
