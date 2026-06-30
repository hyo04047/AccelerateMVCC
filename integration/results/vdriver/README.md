# vDriver head-to-head — raw outputs (session 16, 2026-06-30)

Same-hardware build of vDriver's MySQL 8.0.17 fork + native chain-length comparison vs a vanilla 8.0.17 build.
Full writeup, build recipe, and caveats: [`docs/phase3-vdriver.md`](../../../docs/phase3-vdriver.md).

## Files
- `vd_cs_vanchain.err` / `vd_cs_vdchain.err` — mysqld error logs containing the `[HYU_CHAIN]: <loop_cnt>` lines
  (version chain-walk length of a held READ-ONLY view reading id=1, at cumulative churn 0,100,…,1000).
  - vanilla: loop_cnt = `0 100 200 … 1000` (linear in churn).
  - vDriver: loop_cnt = `0 4 3 6 2 3 3 3 5 5 6` (bounded ≤ 6).
- `vd_cs_vanchain.out` / `vd_cs_vdchain.out` — the held-RO session output; both return the snapshot value (ORIG)
  on all 11 reads (correctness).
- `vd_held_{van,vd}_{64M,4G}.out` — held pre-churn snapshot + 2000-round churn + full-table held deep read.
  vanilla 64M deep read = 5.02 s (undo-I/O cliff), 4G = 0.49 s, both correct (SUM(LENGTH(pad))=4000 = pre-churn).
  vDriver rows on this wide-row full-scan table are outside its validated point-read envelope (see doc §5).
