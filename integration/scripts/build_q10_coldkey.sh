#!/usr/bin/env bash
# Phase 2 / ⓝ9 cold-key footprint + graceful non-admission. The cache keeps one interval_list_header + Kuku
# slot per distinct key, never freed -> footprint = O(distinct keys touched), separate from the GC-bounded
# VERSIONS. A `headers` counter (drained-reporter) quantifies it; `dropped` counts keys not cached because
# the cuckoo table is full (they fall back to the vanilla walk). Two regimes:
#   - 40k-key table (< Kuku capacity): headers plateaus at the key set, live_versions GC-bounded -> bounded.
#   - 200k-key table (> capacity, kuku_log2=16=65536 bins): graceful non-admission caps headers (~0.66 load)
#     instead of the old unbounded churn (2.6M) / crash; non-admitted keys MISS -> vanilla, construct_BAD=0.
# 1G BP, GC on, 8 update + 4 read threads, uniform (max distinct-key reach). See docs/phase2-q3-llt.md ⓝ9.
exec > /mnt/c/Users/USER/q10_coldkey.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run(){  # $1=table_size  $2=tag
  local TS="$1" tag="$2"; local MLOG=/mnt/c/Users/USER/q10_${tag}_mysqld.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_GC=1 ACCEL_RETENTION_MS=2000 ACCEL_RETENTION_CAP=512 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=1G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=$TS prepare >/dev/null 2>&1
  sysbench oltp_update_non_index $C --tables=1 --table-size=$TS --threads=8 --time=50 --rand-type=uniform run >/dev/null 2>&1 &
  local CH=$!
  sysbench oltp_read_only $C --tables=1 --table-size=$TS --threads=4 --time=50 --rand-type=uniform --skip-trx=off run >/dev/null 2>&1 &
  local RD=$!
  wait $CH; wait $RD
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 5; pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 1
  echo "########## table-size=$TS ($tag) ##########"
  echo "  --- headers (plateau) | live_versions (GC-bounded) | dropped (vanilla fallback) ---"
  grep -E '\[accel\] retention:' "$MLOG" | awk '{for(i=1;i<=NF;i++){if($i~/^t_ms=/)t=$i;if($i~/^headers=/)h=$i;if($i~/^live_versions=/)lv=$i;if($i~/^dropped=/)d=$i}} {print "    "t,h,lv,d}' | sed -n '1p;4p;8p;14p;20p;26p'
  grep -E '\[accel\] (shutdown|consult:)' "$MLOG" | sed 's/^/    /' | head -2
  echo ""
}

echo "=== ⓝ9 cold-key footprint + graceful non-admission (1G BP, GC on, uniform) ==="
run 40000  under_capacity
run 200000 over_capacity
echo "=== DONE (under: headers plateau=key set; over: headers plateau ~0.66*65536, construct_BAD=0, no crash) ==="
