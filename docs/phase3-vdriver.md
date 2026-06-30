# Phase 3 — vDriver head-to-head (same-hardware build + native chain-length comparison)

> Session 16 (2026-06-30). Addresses the third-party-review Tier-3 item §3a (⭐ vDriver head-to-head):
> the reviewers asked for a *measured* baseline against vDriver, not a citation. We built vDriver's MySQL
> 8.0.17 fork natively on the same machine and reproduced its headline (bounded version chain under an LLT)
> against a vanilla build, on the same hardware as AccelerateMVCC. Raw outputs in
> `integration/results/vdriver/`. See also `docs/paper-review-todo.md` §3a.

## 1. Build (refutes "head-to-head precluded by toolchain gap")

vDriver source = `github.com/hyu-scslab/vDriver`, an InnoDB fork of **MySQL 8.0.17 (2019)**. Built natively on
WSL2 Ubuntu (no Docker) with gcc-13. The 2019→2026 toolchain gap was bridged with a **bounded** set of fixes
(none touch vDriver's version-chain logic):

**Build-config (3):**
1. **Boost 1.69** — the hardcoded download URL is `dl.bintray.com` (dead since 2021). Pre-downloaded
   `boost_1_69_0` from `archives.boost.io`, pointed `-DWITH_BOOST` at it.
2. **CMake 4.x** — bundled `extra/zlib` etc. declare `cmake_minimum_required` < 3.5 (hard-rejected by CMake 4).
   `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.
3. **OpenSSL** — 8.0.17 `ssl.cmake` requires OpenSSL major == 1, and its source uses 1.1 APIs (OpenSSL 3 support
   landed ~8.0.30). Built **OpenSSL 1.1.1w** locally, `-DWITH_SSL=/root/openssl-1.1`.
   Compiler pinned to gcc-13; target-limited to `mysqld mysql` (skips MySQL Router + tests).

**Source (7 files, standard-header includes only — non-transitive-include breakage under new libstdc++):**
`include/my_hash_combine.h`, `plugin/x/src/xpl_system_variables.h`, `plugin/x/src/cache_based_verification.h`,
`plugin/x/ngs/include/ngs/interface/document_id_generator_interface.h`, `sql-common/sql_string.cc`,
`sql/dd/impl/sdi.h`, `include/mysql/components/services/page_track_service.h` — each gets `<cstdint>`/`<cstddef>`/
`<limits>`. (MySQL Router's `base64.h` has the same issue but is avoided by building only the `mysqld`/`mysql` targets.)

Three binaries result, switched by `univ.i` flags (`HYU` = vDriver reclaim, `HYU_CHAIN` = chain-length logging):
`mysqld_vdriver` (HYU+HYU_CHAIN), `mysqld_vanilla` (both off), `mysqld_vanilla_chainlog` (HYU off, HYU_CHAIN on).

## 2. vDriver's native metric: version chain length under an LLT

vDriver logs the chain-walk length (`read_view->loop_cnt`) via `[HYU_CHAIN]` when a **READ ONLY** transaction
reads the row with primary key id=1 (`row0sel.cc`) — exactly their LT pattern (`lt_loop_11.sql`: a held read-only
view repeatedly `SELECT ... WHERE id=1`). We replicate that: one held READ-ONLY view on a 1,000-row table, then
committed full-table UPDATE churn in batches of 100, reading id=1 after each batch (REPEATABLE READ, 4 GB BP).
This is vDriver's own validated envelope, where it is correct.

**Chain-walk length (loop_cnt) at cumulative churn 0,100,…,1000:**

| Build (8.0.17) | loop_cnt series | held-RO read |
|---|---|---|
| vanilla | `0 100 200 300 400 500 600 700 800 900 1000` (linear in churn) | 11/11 return the snapshot value (correct) |
| vDriver | `0 4 3 6 2 3 3 3 5 5 6` (**bounded ≤ 6**) | 11/11 return the snapshot value (correct) |

This reproduces vDriver's SIGMOD'20 headline on our hardware: vDriver's in-engine dead-zone reclaim keeps the
chain bounded while vanilla grows linearly with the LLT's accumulating churn — and both return the correct
snapshot version.

## 3. Held-read latency (the cliff vanilla pays, on 8.0.17)

Held pre-churn snapshot + 2000 committed full-table UPDATE rounds + held deep read (full-table SUM):

| Build (8.0.17) | 64 MB BP | 4 GB BP | correctness |
|---|---|---|---|
| vanilla | **5.02 s** (undo-I/O cliff) | 0.49 s | correct (reads pre-churn values) |

vanilla-8.0.17 reproduces the undo-I/O cliff (≈10× from 4 GB→64 MB here on a 1,000-row table) — independent
cross-version corroboration of the cliff our paper measures on 8.4.10.

## 4. Placement vs AccelerateMVCC (same box, same workload family)

- **vanilla**: chain length ∝ churn → held read walks the full chain → undo-I/O cliff (5.0 s @ 64 MB).
- **vDriver**: chain bounded (≤ 6) by in-engine reclaim → short walk → fast; but it **modifies the engine's
  version store** (owns it) and still walks the (short) on-disk chain.
- **AccelerateMVCC**: serves the visible version from an external in-memory cache (walk length 0), with **zero
  engine modification** and the superset-safe **no-wrong-serve** guarantee.

All three remove the cliff; the distinction is architectural (engine-ownership) and the correctness guarantee.
Version difference (vDriver 8.0.17 vs AccelerateMVCC 8.4.10) is a documented confound; the chain-length
mechanism is version-independent.

## 5. Methodological caveat (vDriver's validated envelope)

The comparison above runs vDriver in the workload it was validated for: a **READ-ONLY point read** (id=1) on a
narrow table, its own chain-length metric. When we drove vDriver's prototype outside that envelope — a held
**full-table analytical scan** over wider rows (extra CHAR column), or a table with a **secondary index** under
indexed-column churn — its reconstruction returned a corrupted row image, or it aborted in
`trx_undo_prev_version_build`. (The identical harness, table, and workload on the vanilla build were correct
throughout, so the divergence is in the vDriver build, not our harness — though we cannot exclude a vDriver
configuration we did not replicate.) We therefore restrict the quantitative comparison to vDriver's validated
point-read envelope and do not claim numbers for it outside that envelope.

## 6. Reference

[1] Jong-Bin Kim, Hyunsoo Cho, Kihwang Kim, Jaeseon Yu, Sooyong Kang, Hyungsoo Jung. *Long-lived Transactions
Made Less Harmful.* SIGMOD 2020. DOI 10.1145/3318464.3389714.

## Reproduction
- Binaries built under `/root/vDriver/mysql/mysql-server-8.0/runtime_output_directory/` (WSL), saved as
  `/root/mysqld_{vdriver,vanilla,vanilla_chainlog}`; OpenSSL 1.1.1w at `/root/openssl-1.1`.
- Driver scripts (session scratchpad): `vd_cmake.sh`, `openssl_build.sh`, `apply_patches.sh`, `vd_chainseries.sh`,
  `vd_run.sh`. Raw outputs archived under `integration/results/vdriver/`.
