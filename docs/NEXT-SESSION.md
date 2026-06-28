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
  `build_q5_writeonly.sh`.
- **Phase 2 ⓝ6 CLOSED (세션 11)** — LOB/off-page/virtual/>512B 행은 캡처 시 제외(`trx0rec.cc` 게이트 +512B cap)
  → MISS_INELIGIBLE→vanilla. 4 변형 실측: 제외 행 **ineligible 100%·construct_BAD=0**(off-page LOB 부분 image
  안 서빙=안전 핵심)·small HIT 100%. 커버리지 LOB-heavy서 ~0 붕괴하나 무해 → **캐시 scope=small-row OLTP**(정직한
  Limitation). 재현 `build_q6_coverage.sh`.
- **Phase 2 correctness breadth CLOSED (세션 11)** — composite-PK(a,b)+secondary-index·string-PK·savepoint
  전부 **construct_BAD=0**(mode-2 verify-serve, 4G resident). 캐시가 single-INT-PK 너머 일반화·savepoint는 graceful
  MISS로 안전. 재현 `build_q7_keys.sh`·`build_q8_savepoint.sh`.
  ⚠️ 방법론: correctness 체크는 4G resident+짧은 churn(64M+깊은 churn+secondary는 병리적 느림).
- **Phase 2 ⓝ5 full-mysqld ASan CLOSED — CLEAN (세션 11)** — `-DWITH_ASAN=ON` mysqld서 drainer‖consult‖held
  reader(serve)‖GC‖teardown 동시 스트레스 → **AddressSanitizer 리포트 0**(consult 251k·serve 243,803·construct_BAD=0·
  GC retired 9,114·clean shutdown). full-mysqld TSan은 documented residual. 재현 `build_q9_asan.sh`.
  **→ Phase 2 사실상 완료. 다음 = Phase 3(논문 한글+영문·multi-run/error-bar·패치 vendor·Limitations[ⓝ6·TSan residual]).**
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

**standalone** (정확성 + 동시성, **40 tests**, 5/5 안정):
- Release: `build_d5_walk_std.sh` — `correctness_test.cpp`의 `Consult.*`(serve·gen-gate·FG-α 오라클 포함)+전체 스위트
  (세션 11 `GcRetireOnce.RetentionReporterAccessors` 추가 = capped chain + entries_retired semantics).
- ASan/TSan: `build_d5_walk_san.sh` — UAF/leak/race 0 (28 tests in filter).
- 둘 다 레포 밖 `/mnt/c/Users/USER/`에 있음(편의 스크립트).

**integration** (통합 mysqld, `integration/scripts/`):
- 패치 적용 = `accel_hook.{h,cc}` + `accel_ring.h`를 `~/mysql-server/storage/innobase`로 복사 후
  `cmake --build ~/mysql-build --target mysqld`(증분). accel 헤더는 `-I repo/include`로 해결.
- mysqld 기동 주의: `--user=root`, `--lc-messages-dir=$BUILD/share`, `--mysql-native-password=ON`.
- **런타임 토글(env) — accel_hook.cc가 읽는 13개 전체**:
  - **운영/측정**: `ACCEL_GC=1`(deadzone GC, 기본 off) · `ACCEL_AUTHORITATIVE=2`(verify-serve=walk+byte-compare 후 서빙)
    `=1`(serve-only, walk skip=mode-1 출하 perf) `=0`(shadow, 기본) · `ACCEL_AUDIT_N=N`(mode-1 1-in-N walk-audit,
    기본 1024; mode-1+N=0이면 거부→shadow) · `ACCEL_DRAIN_CAP=N`(⑥ stabilizer: dummy-drain per-cycle cap, 기본
    0=무제한, **⑥-serving 권장 ≈1000**) · `ACCEL_CONSULT_FG=1`(FG-α, 기본 off=측정상 이득 0) · `ACCEL_GEN_GATE=0`
    (진단: gen-gate 끄기, 기본 on) · `ACCEL_PUBLISH=0`(view-registry push 끄기=baseline, 기본 on).
  - **ⓠ3/ⓝ6 측정(세션 11, read-only·기본 off=중립)**: `ACCEL_RETENTION_MS=N`(held-LLT retention reporter cadence ms,
    0=off) · `ACCEL_RETENTION_CAP=N`(per-key chain-walk cap, 기본 512, 0=무제한; tail-only 거대체인 CPU-steal 방지) ·
    `ACCEL_TAIL_ONLY=1`(in-process tail-only GC baseline; ⚠️ throughput ~5× confound, baseline은 실 InnoDB HLL 권장).
  - **test/negative-control 전용**: `ACCEL_PK_MASK_BITS`·`ACCEL_NO_FULL_PK`·`ACCEL_NO_SCHEMA_CHECK`(강제 충돌/게이트
    우회로 가드 작동 증명; 프로덕션 미사용).
- 재현 스크립트: **Phase 2(세션 11)** = `build_q3_{pinned,realistic}.sh`(in-middle 헤드라인)·`build_q5_writeonly.sh`
  (effective speedup)·`build_q6_coverage.sh`(LOB/virtual)·`build_q7_keys.sh`(composite/string-PK/secondary)·
  `build_q8_savepoint.sh`(savepoint)·`build_q9_asan.sh`(full-mysqld ASan, ⚠️ mode-2; mode-1 ASan은 별도 필요).
  C3 = `build_d5_c3.sh`·`build_d5_c3c.sh`·`build_d5_c3c_char.sh`(⑥ 특성화). FG+BG = `build_d5_alpha.sh`·
  `build_d5_gctune{,2,3}.sh`. 그 외 `build_d5_c2.sh`·`build_d5_d6_gc.sh`·`build_d6.sh`(원본 ⑥).

## 로드맵 (다음 작업) — GC-side ✅ + Phase 2 ✅, 다음은 Phase 3
[open-items.md](open-items.md) §0d가 마스터 트래커. **GC-side perf 완료**(C3 출하·⑥ drain-cap·β 불가·α null) +
**Phase 2 완료**(ⓠ3 in-middle 헤드라인 실 InnoDB 생존 20×/40×/63× · ⓠ5 effective ~34× · ⓝ6 LOB Limitation ·
키 일반화·savepoint·full-mysqld ASan, 전부 construct_BAD=0). **남은 것 = Phase 3(논문) — 단, 신뢰성 게이트 3개 먼저**:
- **(논문 전 하드 게이트)** ① **multi-run/error-bar**: 모든 헤드라인이 단일-run인데 ⑥는 non-deterministic(3/4 hold,
  1/4 degrade) → 헤드라인 config N≥3–5 재측·median+min/max. ② **raw 로그 보존**: q*.log 미보존 → `integration/results/`로
  아카이브·커밋(현재 repo 단독 재현 불가). ③ **cold-key 결정**: "memory ∝ live-txn window" 주장이 dataset 스코프선
  cold-key(ⓝ9) 때문에 현재 미성립 → 회수 구현 or 주장 스코핑(Limitation).
- **Phase 3 본체**: **논문 한글본+영문본**(최종 산출물) · REPORT Stage-D+Limitations(ⓝ14) · InnoDB 패치 vendor(.diff, ⓣ10).
- (잔여, 낮은 우선순위) FTS/spatial/partition correctness · full-mysqld TSan(residual) · crash-recovery/ephemeral
  rebuild(ⓣ17) · ⑤b 0.16s(이미 0.22s reuse) · mode-1 ASan run.
