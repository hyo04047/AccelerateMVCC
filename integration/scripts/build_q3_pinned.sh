#!/usr/bin/env bash
# Phase 2 / ⓠ3 PINNED headline: concentrate updates on a small hot set (table-size=10) so per-key version
# chains go deep, then compare -- in the SAME run, no confound -- the cache's retained VERSIONS
# (live_versions = drained - entries_retired, a clean version-unit count) against InnoDB's History List
# Length. Deadzone GC on + 8 readers (the HTAP gap that lets the deadzone reclaim the in-middle). Sweep LLT
# duration: InnoDB HLL grows linearly (purge stalled by the LLT); the deadzone keeps the cache bounded -> the
# ratio grows with the LLT window. See docs/phase2-q3-llt.md.
#
# Prereq: row0vers at 4d-2 (build_d4d2.sh) + the ⓠ3 retention reporter compiled into accel_hook.cc.
exec > /mnt/c/Users/USER/q3_pinned.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
SUMMARY=""

run(){  # $1=llt_dur  $2=tag
  local dur="$1" tag="$2"; local MLOG=/mnt/c/Users/USER/q3_pin_${tag}_mysqld.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 3; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_GC=1 ACCEL_RETENTION_MS=1000 ACCEL_RETENTION_CAP=0 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=256M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=10 prepare >/dev/null 2>&1
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<SQL
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT SUM(k) FROM sbtest1;
SELECT SLEEP($((dur+4)));
COMMIT;
SQL
  ) > /dev/null 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=10 --threads=8 --time=$dur run >/dev/null 2>&1 &
  local CH=$!
  sysbench oltp_read_only $C --tables=1 --table-size=10 --threads=8 --time=$dur --skip-trx=off run >/dev/null 2>&1 &
  local RD=$!
  sleep $((dur-2))
  local HLL=$(Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length' | grep -oE '[0-9]+' | head -1)
  wait $CH; wait $RD; wait $SNAP
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 5; pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 1
  local PEAK=$(grep -E '\[accel\] retention:' "$MLOG" | awk '{for(i=1;i<=NF;i++){if($i~/^max=/){v=substr($i,5)+0;if(v>mx)mx=v} if($i~/^live_versions=/){l=substr($i,15)+0;if(l>ml)ml=l}}} END{printf "%d %d",mx,ml}')
  local CMAX=$(echo $PEAK | awk '{print $1}'); local LIVEV=$(echo $PEAK | awk '{print $2}')
  local RATIO="n/a"; [ -n "$LIVEV" ] && [ "$LIVEV" -gt 0 ] && [ -n "$HLL" ] && RATIO=$(awk "BEGIN{printf \"%.1f\", $HLL/$LIVEV}")
  printf "pinned llt=%-3s | InnoDB_HLL=%-9s cache_live_versions=%-9s RATIO=%-7s chain_epochs=%-6s\n" "$dur" "$HLL" "$LIVEV" "${RATIO}x" "$CMAX"
}

echo "=== ⓠ3 PINNED (table-size=10, 256M BP, deadzone GC, 8w+8r): ratio grows with LLT ==="
for dur in 15 30 60; do run $dur s${dur}; done
echo "=== DONE ==="
