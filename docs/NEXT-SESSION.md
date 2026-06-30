# 재개 가이드 (Handoff)

> 새 세션이 이전 대화 없이 그대로 이어가기 위한 **실무 가이드**. 프로젝트 개요·아키텍처·로드맵은
> [README.md](README.md), 남은 작업의 상세 트래커는 [open-items.md](open-items.md), 세션별 서사는
> [progress-log.md](progress-log.md), 설계 근거는 `design-*.md`에 있습니다.
>
> 최종 갱신: **2026-06-29** (세션 13 — Phase-3 전 최종 검토: 멀티에이전트 review→triage, **동시-HTAP ⑥/⑤ 확인(DoD config)**, hardening 4건 + 512B(A) wide-in-page 구현·실증, future-work 재분류. **개발 완전 완료(동시성까지 실측), 다음 = Phase 3**)

## 현재 위치 (한눈에)
- **세션 14–15 (2026-06-30) — Phase 3 측정 + 논문 + 3자 리뷰 (대량 진행, 세션 이동).** ⓐ **gate ① error-bar
  멀티런 4종**(q11 ⑥ payoff 64M ~290× median·2/8 degrade · q15 동시-HTAP ~18× · q3 메모리 19.5/40.5/81.9× ·
  q5 effective 64M ~29×; **전 run construct_BAD=0**; raw-log+CSV `integration/results/`). ⓑ **④ 표준 TPC-C 평가**
  (`build_q17_tpcc_{smoke,latency}.sh`·`docs/phase3-tpcc.md`: serve byte-정확·**D8 sizing 16%→64% kuku16→21**·D6
  wide-row·latency ~1.4×=undo-reconstruction-accelerator regime; `ACCEL_KUKU_LOG2` env 추가·mysqld 재빌드). ⓒ
  **논문 한/영 초안 §1–§8 + figure 5종**(`docs/paper/paper-{en,ko}.md`, **en=canonical native·ko=참고/번역투**;
  related-work 프레이밍=독립진행·deadzone만 vDriver 차용). ⓓ **3자 리뷰 패널(6 agents) → "Major revision
  (accept-able core)" + 리비전 라운드 1**(Tier 1+2 반영, `da50c9f`). **재개 지점 = `docs/paper-review-todo.md`**
  (리뷰 verdict·Tier 1+2 완료·Tier 3 남은 측정·**vDriver 빌드 레시피**). **다음 = ⭐ vDriver head-to-head 빌드
  timeboxed 시도**(코드 있음, `/root/vDriver` 이미 clone=MySQL 8.0.17 fork; Docker 없어 gcc-13 native 빌드 리스크,
  wall이면 발표수치 인용 fallback) + 가벼운 Tier 3(GC-on memory+speedup 공존·N≥5 vanilla·중간 hot-table·CH 쿼리).
  커밋 `c26027f`…`da50c9f` 전부 push. ⚠️ 실행 인프라(WSL·**setsid**·pkill `-x` 함정)=메모리 `acceleratemvcc-integration-run-infra`.
- **세션 13 — Phase-3 전 최종 검토 + 잔여 dev 완료.** 멀티에이전트 검토(38 findings)→사용자 원칙(개선=지금·새설계만
  향후연구)으로 전수 triage. **핵심: DoD 원문 config(churn 도는 중 held read)를 처음 측정(`build_q15_concurrent.sh`)** —
  GC-on/off 모두 64M serve 0.2~3.9s vs vanilla 60s(~16–300×)·mode-2 construct_BAD=0 → **동시성에서도 헤드라인 생존,
  새 dev 갭 없음.** 잔여 dev 완료: hardening 4건(`acd6461` mids-sorted release fail-closed·seqlock begin!=0 assert·
  reuse sharp-edge / `6618760` mode1-vrow 게이트) + DDL straddle·적대적 savepoint 검증(`b9924b6`, construct_BAD=0) +
  **512B(A) wide-in-page**(`4809081`: cap build-overridable[기본 512=회귀0]+`build_q16_widerow.sh` cap2048서 HIT1000/1000
  construct_BAD=0). 코드로 SAFE 확정(dev 불필요): seqlock tear·pk_len 256-truncation·ambiguity-guard·head-prepend·
  secondary-index(공유 builder+q7). **재분류**: off-page LOB(512B B)·shared-nav는 future-work 아니라 **scope Limitation/
  measured-negative**(구현 주제); 진짜 향후연구=연구방향(다른 엔진/isolation/분산 MVCC/형식검증). standalone Release40/
  ASan29/TSan29 green·mysqld 재빌드(hardening+vrow) rc=0·construct_BAD=0 도처. **이어서 Phase 3 일부 진행(빌드-무관 묶음)**:
  gate ② raw-log 아카이빙 해결(`.gitignore` `!integration/results/*.log` + 세션 로그 18개 커밋 `40bbf06`) · gate ⑤
  no-wrong-serve **semi-formal 논증** 초안(`docs/design-D7-no-wrong-serve.md`, 커밋 `c4a845b`) · gate ③ cold-key **스코핑
  결정**(`docs/design-D8-memory-scope.md`: 2-term 메모리 bound·eviction NO-GO·"용량 N 안 working set" 스코프+sizing).
  **남은 Phase 3 = ① multi-run/error-bar(빌드-heavy) · CH-benCHmark/TPC-C(빌드-heavy) · 논문 한/영.** 빌드-heavy는 세션
  안정적일 때 권장. push 완료.
- **세션 12 — dev-completeness pass DONE (개발 완전 완료).** 전수 감사(14 task)로 코드 hygiene·crash-recovery(ⓣ17)·
  vendoring(ⓣ10)·GC/splice dedup·하드닝·관측성을 닫고, 큰 레버 둘(roll_pred chase·DIVA interval tree)은 적대 리뷰서
  **NO-GO**(design-D5-gc §14), pool allocator는 데이터 근거로 보류. construct_BAD=0 도처·Release 40/ASan 29/TSan 29 green.
  **모든 결정·스킵 기록 = open-items §0e.** 새 산출물: `build_q12_crash_recovery.sh` · in-repo `build_d5_walk_{std,san}.sh` ·
  `accel_microbench`(분리된 벤치) · `ctest`(correctness만) · `innodb-8.4.10-accel.diff`(패치 vendor). **다음 = Phase 3(논문).**
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
- **Phase 3 전 사전 감사 + 정리 (세션 11, 커밋 `5945adf`)** — 멀티에이전트 감사(6에이전트, 42 findings)로 doc drift·
  미기록 개선 발굴 후: open-items §0 진단 supersede·ⓝ1/ⓝ4 CLOSED·README/NEXT-SESSION 로드맵 Phase 3로·토글 목록
  6→13개·반환코드 5 문서화. **mode-1 serve-only 출하 경로도 ASan CLEAN**(build_q9는 mode-2만), standalone 테스트
  +1(capped chain+entries_retired). phase2 doc 상단에 측정 캐비엇 블록(단일-run·로그 미보존 등).
- **cold-key (ⓝ9) 측정 → "터짐" 수정 (세션 11, 커밋 `281a978`)** — `headers_created` 카운터로 footprint=admitted
  distinct 키(~72B/키·GC무관) 정량화: 용량 아래 plateau(bounded). **진짜 한계=Kuku 용량(kuku_log2=16=65536 bin)**:
  초과 시 old code가 header churn(2.6M)/crash → **graceful non-admission fix**(`kuku_full_`·실패 header 미삭제[UAF
  회피]·초과 키 vanilla fallback): headers plateau·메모리 bounded·**construct_BAD=0·crash 없음**. "memory∝working set"은
  Kuku 용량 안에서 defensible. **잔여=진짜 cold-key EVICTION(LRU·Kuku erase+EBR, deferral)**. 재현 `build_q10_coldkey.sh`.
  **→ Phase 2 + GC-side + 사전감사 완료. 엔지니어링은 Phase 3 시작에 defensible(correctness 갭 0, construct_BAD=0 도처).**
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
   **40 green** 1회 → 필요 시 `build_d5_walk_san.sh`(ASan/TSan 29).
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
  **세션 13** = `build_q13_ddl.sh`(DDL straddle)·`build_q14_savepoint.sh`(적대적 savepoint)·`build_q15_concurrent.sh`
  (**동시-HTAP ⑥/⑤, DoD config**; `ACCEL_GC=1 Q15LOG=q15_gc_concurrent`로 GC-on variant)·`build_q16_widerow.sh`
  (512B(A) wide-in-page; rebuild가 `ACCEL_IMG_MAX_BYTES`+`accel_cbuf`를 lockstep으로 올림, 끝에 512 복원).

## 로드맵 (다음 작업) — GC-side ✅ + Phase 2 ✅, 다음은 Phase 3
[open-items.md](open-items.md) §0d가 마스터 트래커. **GC-side perf 완료**(C3 출하·⑥ drain-cap·β 불가·α null) +
**Phase 2 완료**(ⓠ3 in-middle 헤드라인 실 InnoDB 생존 20×/40×/63× · ⓠ5 effective ~34× · ⓝ6 LOB Limitation ·
키 일반화·savepoint·full-mysqld ASan, 전부 construct_BAD=0). **남은 것 = Phase 3(논문) — 단, 신뢰성 게이트 3개 먼저**:
- **(논문 전 하드 게이트)** ① **multi-run/error-bar**: 모든 헤드라인이 단일-run인데 ⑥는 non-deterministic(3/4 hold,
  1/4 degrade) → 헤드라인 config N≥3–5 재측·median+min/max. ② **raw 로그 보존**: q*.log 미보존 → `integration/results/`로
  아카이브·커밋(현재 repo 단독 재현 불가). ③ **cold-key EVICTION 결정(사용자 미정)**: graceful non-admission("터짐" 제거)은
  세션 11서 완료(headers bounded·construct_BAD=0). 남은 건 *이동하는* working set 추적용 진짜 EVICTION(LRU·Kuku erase+EBR,
  lock-free race=적대적 리뷰 필요) — 논문이 "shifting working set 추적"을 주장할지로 결정. 안 하면 "용량 N 안에서 bounded" 스코핑.
- **Phase 3 본체**: **논문 한글본+영문본**(최종 산출물) · REPORT Stage-D+Limitations(ⓝ14) · InnoDB 패치 vendor(.diff, ⓣ10).
- (잔여, 낮은 우선순위) FTS/spatial/partition correctness · full-mysqld TSan(residual) · crash-recovery/ephemeral
  rebuild(ⓣ17) · ⑤b 0.16s(이미 0.22s reuse).
