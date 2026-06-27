#!/usr/bin/env bash
# D-5 C3-c: the mode-1 serve-only SHIP gate. §10 prerequisite: a mode-2 verify-serve SOAK (volume baseline
# that the lineage walk + serve construction is correct) BEFORE trusting mode-1's walk-skip. Then the mode-1
# ship gate, a 4-way AND on the historically-divergent workloads (oltp_read_write = index update + delete/
# insert; oltp_write_only = write-heavy cross-gen stress):
#   construct_BAD == 0  (mode-2 soak AND mode-1 audit)
#   retire windowed > 0 AND dummy > 0      (both GC retire paths ran)
#   HIT-rate floor: hit/calls not collapsed (coverage survives the gen-gate)
#   audited > 0  (the walk-audit actually sampled)
# (mysqld already built by build_d5_c3.sh -- this only runs.) The ⑥ perf payoff in mode-1 is measured
# separately by build_d5_d6_gc.sh (does the held-reader cliff stay flat with the gen-gate on?).
exec > /mnt/c/Users/USER/build_d5_c3c.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run_one() {  # $1=label $2=workload $3=threads $4=time $5...=env
  local label="$1"; local wl="$2"; local threads="$3"; local time="$4"; shift 4
  local MLOG=/mnt/c/Users/USER/d5_c3c_$label.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2
  echo ""; echo "--- RUN $label: $wl threads=$threads time=$time env: $* ---"
  env "$@" "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --max-connections=512 --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  sysbench $wl $C --tables=4 --table-size=2000 --threads=$threads --time=$time --rand-type=uniform run 2>&1 | grep -E 'transactions:'
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null
  for i in $(seq 1 25); do pgrep -f "$MYSQLD" >/dev/null 2>&1 || break; sleep 1; done
  if pgrep -f "$MYSQLD" >/dev/null 2>&1; then echo "  SHUTDOWN HANG"; pkill -9 -f "$MYSQLD" 2>/dev/null; else echo "  shutdown clean"; fi
  grep -E '\[accel\] consult:|\[accel\] audit:|\[accel\] gc: enabled|REFUSING mode-1' "$MLOG"
}

# fresh datadir + prepare once (oltp_read_write schema covers both read_write and write_only).
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > /mnt/c/Users/USER/d5_c3c_init.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=4 --table-size=2000 prepare 2>&1 | tail -1
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 3; pkill -9 -f "$MYSQLD" 2>/dev/null

echo ""; echo "=== 1. mode-2 SOAK (§10 prereq): verify-serve 60s, construct_BAD must be HARD 0 at volume ==="
run_one soak_m2_rw oltp_read_write 32 60 ACCEL_AUTHORITATIVE=2 ACCEL_GC=1
echo ""; echo "=== 2. mode-1 SHIP gate: oltp_read_write 60s (gate: construct_BAD=0, audited>0, retire both>0, HIT-floor) ==="
run_one ship_m1_rw oltp_read_write 32 60 ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_AUDIT_N=64
echo ""; echo "=== 3. mode-1 SHIP gate: oltp_write_only 40s (write-heavy cross-gen stress) ==="
run_one ship_m1_wo oltp_write_only 32 40 ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_AUDIT_N=64
echo ""; echo "=== DONE (mode-1 ships only if: soak bad=0, ship bad=0, audited>0, retire windowed+dummy>0, hit-rate not collapsed) ==="
