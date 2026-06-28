# 재개 가이드 (Handoff)

> 새 세션이 이전 대화 없이 그대로 이어가기 위한 **실무 가이드**. 프로젝트 개요·아키텍처·로드맵은
> [README.md](README.md), 남은 작업의 상세 트래커는 [open-items.md](open-items.md), 세션별 서사는
> [progress-log.md](progress-log.md), 설계 근거는 `design-*.md`에 있습니다.
>
> 최종 갱신: **2026-06-28** (세션 11 — Phase 2 착수: ⓠ3 in-middle 헤드라인이 실 InnoDB에서 생존·확정)

## 현재 위치 (한눈에)
- **Phase 2 ⓠ3 CLOSED (세션 11)** — write-heavy OLTP + held LLT + 동시 HTAP 리더 하에서 캐시 보존이 bounded
  (~6–9k versions), InnoDB HLL은 LLT 시간에 선형 증가 → **비율이 LLT 나이에 선형 성장: 20×/40×/63×@15/30/60s**
  (realistic full-table; pinned hot-set 10×/21×/42×). 프로젝트 중심 헤드라인이 실 InnoDB서 생존, **5-3 후퇴
  트리거 안 됨.** 승리는 동시 read-view 리더의 gap을 요구(리더0 대조군 0.9×=승리 0). 새 계측(retention reporter
  env `ACCEL_RETENTION_MS`·`entries_retired` version 카운터, 둘 다 read-only·기본 off). 상세 [phase2-q3-llt.md](phase2-q3-llt.md).
  재현 `integration/scripts/build_q3_{pinned,realistic}.sh`.
- **Phase 2 ⓠ5 CLOSED (세션 11)** — "22% MISS effective speedup" 우려는 held analytic reader엔 해당 없음:
  write-heavy+delete/insert churn서도 **HIT ~99.8–100%**(22%는 head 근처 짧은 reader=캐시 불필요 대상).
  effective speedup resident ~3×·**I/O-bound(64M) ~34×**(undo I/O 23,783→352)·construct_BAD=0. 재현
  `build_q5_writeonly.sh`. **다음 = Phase 2 잔여**(LOB ⓝ6·savepoint·secondary-index·full-mysqld ASan/TSan) → Phase 3(논문).
- **1차 목표 A+B+C 완료**, **최종 D 완료** (populate → consult → authoritative serve → ⑥ 성능 payoff).
- **⑤a-2 완료** — deadzone GC가 통합 mysqld 안에서 실제로 돈다(pushed InnoDB clock + active-view registry,
  amortized windowed sweep, construct_BAD=0·race/UAF 0·메모리 유계). **5-2b C1·C2 완료**(mode-2 verify-serve가
  GC 위에서 정확, 49만 served construct_BAD=0).
- **C3(mode-1 serve-only 안전 출하) 완료** — gc_generation 2nd firewall(race detector·mode-1 한정) +
  1-in-N walk-audit(observe-only·N=0이면 거부) + 4-layer 분업. construct_BAD=0 도처. 커밋 `6025021`·`3b21003`.
  상세 design-D5-gc §10.1.
- **⑥ chain-sever → drain-cap으로 안정화 (FG+BG 스테이지 완료, design-D5-gc §13)** — GC storm이 navigation
  경로 회수 시 consult가 MISS→정답 walk로 degrade(construct_BAD=0 항상)였으나, **GC-tuning drain-cap이 ⑥를
  stable로**: cap=0 2/8 → **cap≤1000 0/6 degrade**(30+ run·construct_BAD=0·메모리 ∝window=⑤ 유지). ⑥-serving
  권장 `ACCEL_DRAIN_CAP≈1000`(default 0). **β(navigation 구조)는 구조적 불가 재확인, α(FG reclaim 통합)는 측정상
  이득 0**(consult가 OLTP 비용의 무시할 fraction). 커밋 `71f0cfd`·`1f92ea2`, standalone 39 5/5 안정.
- **다음 = Phase 2**(워크로드 폭: write-heavy+LLT in-middle 이득·LOB·savepoint·22% MISS effective speedup)
  → Phase 3(InnoDB 패치 vendor·REPORT Limitations·multi-run/error-bar·논문 한글+영문). 상세 [open-items.md](open-items.md) §0c.

## 새 세션 시작 절차
1. **맥락**: [README.md](README.md) §현황 → [open-items.md](open-items.md) §0b(남은 작업) → 필요 시
   [progress-log.md](progress-log.md) 최신 엔트리.
2. **검증(맹신 금지)**: `git log --oneline -5` + `git status`(clean) → standalone `build_d5_walk_std.sh`로
   **36 green** 1회 → 필요 시 `build_d5_walk_san.sh`(ASan/TSan 25).
3. **작업 방식**: 작게 + 중간 체크포인트(brief→사인→재진입). correctness-critical 큰 단계는 **적대적
   설계 리뷰 먼저**(⑤a-2·5-2b가 그렇게 진행됨). 답변은 한국어 존댓말·동작 레벨(symbol 덤프 X), technical
   용어는 영어. **성능이 목적, correctness는 전제.**

## 빌드 & 테스트 레시피
**환경**: WSL2 Ubuntu, root 운용. 소스 `/mnt/c/Users/USER/projects/AccelerateMVCC`. standalone 빌드는 WSL
홈 `~/acc-build*`, MySQL 소스/빌드는 `~/mysql-server`(8.4.10)/`~/mysql-build`(gcc-13). PowerShell→wsl로
복잡한 bash 인라인은 따옴표가 깨지니 **스크립트 파일**로 실행하고 출력은 `/mnt/c` 로그로 받아 읽을 것.
긴 빌드는 포그라운드(블로킹)로.

**standalone** (정확성 + 동시성, **39 tests**, 5/5 안정):
- Release: `build_d5_walk_std.sh` — `correctness_test.cpp`의 `Consult.*`(serve·gen-gate·FG-α 오라클 포함)+전체 스위트.
- ASan/TSan: `build_d5_walk_san.sh` — UAF/leak/race 0 (28 tests in filter).
- 둘 다 레포 밖 `/mnt/c/Users/USER/`에 있음(편의 스크립트).

**integration** (통합 mysqld, `integration/scripts/`):
- 패치 적용 = `accel_hook.{h,cc}` + `accel_ring.h`를 `~/mysql-server/storage/innobase`로 복사 후
  `cmake --build ~/mysql-build --target mysqld`(증분). accel 헤더는 `-I repo/include`로 해결.
- mysqld 기동 주의: `--user=root`, `--lc-messages-dir=$BUILD/share`, `--mysql-native-password=ON`.
- **런타임 토글(env)**: `ACCEL_GC=1`(deadzone GC, 기본 off) · `ACCEL_AUTHORITATIVE=2`(verify-serve = walk+byte
  -compare 후 서빙) `=1`(serve-only, walk skip = mode-1 출하 perf) `=0`(shadow, 기본) · `ACCEL_AUDIT_N=N`
  (mode-1 1-in-N walk-audit, 기본 1024; mode-1+N=0이면 거부→shadow) · `ACCEL_DRAIN_CAP=N`(⑥ stabilizer:
  dummy-drain per-cycle reclaim cap, 기본 0=무제한; **⑥-serving 권장 ≈1000**) · `ACCEL_CONSULT_FG=1`(FG-α
  consult cooperative reclaim, 기본 off=측정상 이득 0) · `ACCEL_GEN_GATE=0`(진단: gen-gate 끄기, 기본 on).
- 재현 스크립트: C3 = `build_d5_c3.sh`(walk-audit)·`build_d5_c3c.sh`(soak+ship gate)·`build_d5_c3c_char.sh`
  (⑥ 특성화)·`build_d5_c3c_diag.sh`(gen-gate 격리). FG+BG = `build_d5_alpha.sh`(α A/B)·`build_d5_gctune{,2,3}.sh`
  (drain-cap 곡선). 그 외 `build_d5_c2.sh`(mode-2/GC)·`build_d5_d6_gc.sh`(⑥/GC)·`build_d6.sh`(원본 ⑥).

## 로드맵 (다음 작업) — GC-side 완료, 다음은 Phase 2
[open-items.md](open-items.md) §0c가 마스터 트래커. **GC-side perf는 짜낼 만큼 짜냄**(C3 출하 ✅ · ⑥
drain-cap stabilizer ✅ · β 구조적 불가 · α 측정상 null). 남은 것:
- **Phase 2 — 워크로드 폭(우선)**: write-heavy+LLT에서 in-middle 이득(~5500× 헤드라인)이 실 InnoDB서 생존하나
  (ⓠ3) · LOB/off-page/virtual(ⓝ6) · oltp_read_write 22% MISS effective speedup(ⓠ5) · savepoint(ⓝ15) ·
  secondary-index/composite-PK(mode-1 출하 범위 밖이었음) · full-mysqld ASan/TSan(ⓝ5).
- **Phase 3 — 논문**: InnoDB 패치 vendor(ⓣ10) · REPORT Limitations/Threats(ⓝ14) · multi-run/error-bar ·
  **논문 한글본+영문본**(최종 산출물).
- (낮은 우선순위) ⑤b 0.16s는 memoized-lineage 안전틀에서만(이미 0.22s reuse 있음) · cold-key 회수(ⓝ9).
