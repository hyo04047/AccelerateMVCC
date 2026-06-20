# Stage D integration scripts

WSL/Bash scripts that build vanilla MySQL 8.4, then idempotently patch its InnoDB to call the
AccelerateMVCC index, and verify each increment. They encode the exact recipe documented in
[../../docs/design-D.md](../../docs/design-D.md) (§7 baseline, §8 D-1a, §9 D-1b review, §10 build
integration) and [../../docs/NEXT-SESSION.md](../../docs/NEXT-SESSION.md) §D.

**Path assumptions** (this dev environment — adjust if moving machines):
- repo at `/mnt/c/Users/USER/projects/AccelerateMVCC`, MySQL source `~/mysql-server`, build
  `~/mysql-build`, our standalone build `~/acc-build` (provides the generated `kuku/internal/config.h`).
- Run from PowerShell via `wsl -d Ubuntu -- bash <script>` after `sed -i 's/\r$//' <script>`.
  Each writes a log to `/mnt/c/Users/USER/<name>.log`.

**Order**:
- `build_d0a.sh` deps + sysbench + gcc-13 + shallow-clone MySQL 8.4 · `build_d0b.sh` configure+build
  (gcc-13/ninja, ~11min) · `build_d0c.sh`/`build_d0d.sh` vanilla baseline.
- `build_d1a.sh` populate-hook wiring (CMakeLists + trx0rec patch, count-only) ·
  `build_d1b1.sh` key plumbing (PK hash, applies `../innodb/d1b1_patch.pl`) ·
  `build_d1b2a.sh` standalone ring TSan/ASan · `build_d1b2b.sh` ring+drainer+srv0start lifecycle ·
  `build_d1b3a.sh` compile accelerator+Kuku into innobase · `build_d1b3b.sh`/`build_d1b3b2.sh`
  real insert · `build_d1b4.sh` hardening.

The patched InnoDB files (`storage/innobase/trx/trx0rec.cc`, `srv/srv0start.cc`, `CMakeLists.txt`)
live only in the MySQL tree; these scripts re-apply the patches idempotently, so re-running
reproduces the integration on a fresh `~/mysql-server` checkout.
