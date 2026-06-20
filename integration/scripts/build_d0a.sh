#!/usr/bin/env bash
# Stage D-0a: build deps + sysbench + compiler recon + MySQL 8.4 shallow clone.
exec > /mnt/c/Users/USER/build_d0a.log 2>&1
echo "=== apt-get update ==="
apt-get update -y 2>&1 | tail -3
echo "=== install build deps ==="
apt-get install -y bison libssl-dev libncurses-dev pkg-config libtirpc-dev zlib1g-dev 2>&1 | tail -4
echo "deps rc=$?"
echo "=== compiler availability (apt-cache) ==="
apt-cache policy gcc-12 gcc-13 gcc-14 2>/dev/null | grep -E 'gcc-1[234]:|Candidate:'
echo "=== try install older gcc (13 then 14) ==="
apt-get install -y gcc-13 g++-13 2>&1 | tail -2 || true
apt-get install -y gcc-14 g++-14 2>&1 | tail -2 || true
echo "=== install sysbench ==="
apt-get install -y sysbench 2>&1 | tail -2; echo "sysbench: $(command -v sysbench || echo MISSING)"
echo "=== clone MySQL 8.4 (shallow) ==="
rm -rf ~/mysql-server
git clone --depth 1 -b 8.4 https://github.com/mysql/mysql-server.git ~/mysql-server 2>&1 | tail -4
echo "clone exit observed; checking..."
echo "=== source size + version ==="
du -sh ~/mysql-server 2>/dev/null
cat ~/mysql-server/MYSQL_VERSION 2>/dev/null
echo "=== installed compilers ==="
for c in gcc-12 gcc-13 gcc-14 gcc-15 gcc; do printf '%s: ' "$c"; command -v "$c" || echo no; done
echo "=== DONE ==="
