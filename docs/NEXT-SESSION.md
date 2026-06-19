# 다음 세션 핸드오프 — Step 1c 완료, 다음은 Stage C(HTAP/long-txn 벤치)

> **새 세션은 이 파일을 가장 먼저 읽으세요.** 이전 대화 없이 그대로 이어가기 위한 핸드오프.
> 배경·설계근거 → [design-gc.md](design-gc.md)·[design-1c.md](design-1c.md) / 상태·로드맵 → [README.md](README.md) / 이력 → [progress-log.md](progress-log.md) / 이슈 → [findings.md](findings.md)
> 갱신: 2026-06-20 (세션 3, **Stage 1c 완료** 후)

---

## ⏩ 재개 레시피 (새 세션은 이 순서로)
1. **맥락 복원**: 이 파일(§0→§2→§3) → [progress-log.md](progress-log.md) 최신 세션 항목 → 필요 시 [design-1c.md](design-1c.md)(1c 설계+적대적 리뷰)·[design-gc.md](design-gc.md)(deadzone·동시성·§10 stage C 하니스).
2. **검증(맹신 금지)**: `git log --oneline -8` + `git status`로 HEAD가 §5와 맞는지 확인 → §1 레시피로 **Release + ASan + TSan** 빌드·**20개 correctness green** 확인(+`ebr_test`/`marked_ptr_test`). 헤더 많이 바뀌었으니 재빌드됨.
3. **보고 후 시작**: 위 결과 짧게 보고 → **Stage C(HTAP/LLT 벤치)** 진입(§6). 1차 목표 A+B+C의 마지막이자 실제 결과물.
- 작업 방식: **작게 + 중간 체크포인트** / 설명은 **알고리즘·설계 레벨**(함수·코드명 덤프 X, 단 표준 용어는 영어 그대로). **성능이 목적 — correctness는 전제, no-crash가 아니라 visibility로 검증**(메모리 참조).

---

## 0. 30초 요약
- **프로젝트**: 디스크 DBMS(InnoDB) MVCC를 가속하는 in-memory 인덱스(Kuku hash → epoch 기반 interval list of undo metadata pointers) + deadzone GC. InnoDB undo는 안 건드리고 메타데이터 포인터만 compact 유지. **궁극 목적 = InnoDB HTAP/LLT 성능 향상**(chain length↓ → undo I/O·latch↓ → throughput↑).
- **완료**: A ✅ · B ✅ · 1a ✅ · 1b ✅ · **1c ✅ (0–6)** — FG cooperative unlink(reader가 dead non-head epoch 직접 mark+CAS-splice) + 전용 BG GC + multi-producer EBR 회수 + **tight-bound deadzone**. multi-writer‖multi-reader-unlink‖BG GC를 ASan(UAF/double-free 0)/TSan(race 0)/진행성으로 검증(20 테스트).
- **stage C 전 보류 3건(#1·#2·#5) 전부 해소**: #1 EBR slot lease(1c-0), #2 dummy-overflow drain(1c-3), #5 cold dead head → **tight bounds가 dissolve**(head는 현재 값이라 dead 아님).
- **적대적 코드리뷰 2회**(1c-2/1c-4)가 blocker 3건 잡음 — 특히 **tight bounds**: nominal deadzone이 epoch nominal 범위를 xmax로 써서 reader/LLT가 보는 version을 over-prune하던 **pre-existing correctness 버그**(BG도 잠복). 실제 xmax(`superseded_ts`)로 판정하게 고침. = LLT correctness 핵심.
- **다음 = §6 Stage C**: vDriver Zipfian skew + 60s LLT 하니스 이식, version-chain length CDF vs baseline.

---

## 1. 환경 & 빌드/테스트 레시피 (그대로 따라하면 됨)
- **WSL2 Ubuntu 26.04, root로 운용**(sudo 불필요). 소스: `/mnt/c/Users/USER/projects/AccelerateMVCC`. 빌드: WSL 홈 `~/acc-build`(Release)·`~/acc-build-asan`·`~/acc-build-tsan`.
- ⚠️ **PowerShell→wsl로 복잡한 bash 인라인 X.** **스크립트 파일**로 쓰고 (예시 `/mnt/c/Users/USER/build_test_*.sh` 남아있음) `exec > /mnt/c/.../log 2>&1`로 파일에 받아 Read. **wsl 호출은 PowerShell 툴에서**(Git Bash로 `/mnt/c/...` 넘기면 경로 깨짐). `/tmp`는 wsl 호출 사이 비워질 수 있으니 한 스크립트 안에서 컴파일+보고를 끝낼 것.
- **Release**: `cmake -S <src> -B ~/acc-build -DCMAKE_BUILD_TYPE=Release` → `cmake --build ~/acc-build --target test_with_google -j$(nproc)`.
- **테스트 필터(20개)**: `--gtest_filter='MvccVisibility.*:GcDeadzone.*:GcEndToEnd.*:GcEbrIntegration.*:GcSharedDescriptor.*:GcRetireOnce.*:GcBackstopDrain.*:GcFgUnlink.*:GcScale.*'` (필터 없이 돌리면 옛 insert 벤치 + Kuku `LocFuncTests.Randomness`[알려진 무해 실패]가 섞임).
- **ASan**: `-DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address"`, 실행 `ASAN_OPTIONS=detect_leaks=0`(구조상 의도된 누수 — UAF/double-free만 본다). **TSan**: `address`→`thread`(별도 빌드 디렉토리).
- **별도 타깃**: `--target ebr_test`(EBR slot lease 단위, churn/overflow 포함), `--target marked_ptr_test`. gcc 15.2 / cmake 4.2. 무해 경고: googletest deprecation, FetchContent CMP0135, `can_pruning`의 pre-existing sign-compare.
- 동시성 디버깅: hang은 `timeout -s KILL N <bin>; echo $?`(124=hang), gdb 설치됨. ASan 바이너리에 `stdbuf` X.

---

## 2. Step 1c — 완료 기록 (증분 0–6, 1c-5 dissolved)
> **1c는 끝났다.** 상세는 [progress-log.md](progress-log.md)·[design-1c.md](design-1c.md). 요지:
- **확정 설계(왜)** — 세 축 분리: 논리(어느 버전 dead)=deadzone / 물리 회수 안전=per-traversal EBR / 물리 unlink 일관성=marked pointer(Harris). FG(reader)도 dead non-head epoch을 직접 떼어내 chain을 짧게(payload), **retire는 BG 단독**, 회수는 EBR grace.
- **증분**: 1c-0 EBR slot lease(#1) · 1c-1 shared deadzone descriptor publish+judge · 1c-2 retire-once state machine(LIVE→CHAIN_DETACHED→RETIRED, 단일 state-gated retire)+version-chain 전부 CAS · 1c-3 full-bucket backstop+dummy drain(#2, Treiber) · 1c-4 **FG cooperative unlink + tight-bound deadzone** · 1c-5 **tight bounds가 #5 dissolve** · 1c-6 long_live_epochs compaction + scale/LLT 검증.
- **retire-once 핵심(주의)**: state gate는 `en->state` 안에 살아서 `en`이 alive일 때만 idempotent → **node당 swept wrapper 1개** 불변식에 의존(1c-3 drain은 소유권 *transfer*, 복제 X). [design-1c.md](design-1c.md) §7·§8.
- **검증**: 20 correctness 테스트 Release/ASan/TSan green. `GcScale.HighConcurrencySkewedWorkload`(16스레드/400k/skew), `GcScale.LongLivedReaderConsistentUnderHeavyGc`(LLT), `GcDeadzone.TightBoundDoesNotOverPruneNeededVersion`(finding-2 재현), `GcFgUnlink.*`, `GcRetireOnce.*`, `GcBackstopDrain.*` 등.

---

## 3. 결정 잠금 (재논의 금지 — 근거는 design-gc.md / design-1c.md)
- **deadzone = vDriver Theorem 3.1**(`IsInDeadZone`/`SegIsInDeadZone`). 판정은 **tight bounds**: epoch의 실제 `[min_trx_id, superseded_ts]`(superseded_ts = 다음-newer version begin-ts; head는 ∞=절대 dead 아님). nominal 범위는 **over-prune correctness 버그**라 폐기.
- **동시성**: hot path(read/insert) lock-free / unlink 일관성 = marked pointer / reclamation = per-traversal EBR / FG 협조 unlink + BG retire+reclaim. head는 insert가 prepend·append하는 유일 지점이라 **절대 prune 안 함**(tight bounds로 head는 dead 아님 → head-prune 자체가 불필요·동시성 문제 dissolve).
- **GC = 단일 BG 액터(전용 스레드)**. windowed sweep(bounded/cycle) + low-cadence full-bucket backstop(correctness 받침) + dummy drain + compaction. 전부 BG 단독 순차.
- **provenance**: deadzone = vDriver 파생(정승연, `dead_zone.c` 추출). 보고서엔 vDriver 출처·PostgreSQL License 표기.

## 4. 후속/평가 후보 (지금 건드리지 말 것 — C 결과로 우선순위)
- design-gc §9.3: hot/cold/LLT version classification, multi-granularity 노드, **list→DIVA interval tree**(LLT 하 chain을 log로 bound), tagged-pointer reclamation.
- 잔여 perf 미세: cold record head wrapper가 bucket 유지 → long_live_epochs가 compaction에도 live-bucket 수만큼은 유지(correctness 아님). 별도 pending-list 리팩터는 C 데이터 보고.

## 5. 현재 repo 상태
- branch **master**, working tree **clean**, **origin/master까지 push 완료**. HEAD = 이 핸드오프 docs 커밋(마지막 **코드** 커밋 = `08f5313` 1c-6 위). 세션 3 = `30d3a83`(1c-0) ~ 최신 핸드오프(총 ~10커밋, 1c 전체).
- 1c 신규/변경 파일: `include/interval_list.h`(epoch_node `state`+`superseded_ts`), `include/epoch_table.h`(retire-once helpers·backstop·drain·compaction·tight `can_prune_epoch`), `include/accelerateMVCC.cpp`(insert `superseded_ts` set + search FG unlink), `include/accelerateMVCC.h`(metrics/test 접근자), `include/epoch_reclaimer.h`(slot lease + overflow pin), `correctness_test.cpp`(20 테스트). docs: `design-1c.md`, `progress-log.md`, `findings.md` 갱신.

## 6. 로드맵 위치 — 다음은 Stage C
A ✅ → B ✅ → 동시성 하드닝(1a ✅ → 1b ✅ → **1c ✅**) → **C(HTAP/long-txn 벤치) ← 다음** → (최종) D(InnoDB 통합). 1차 목표 A+B+C, 최종 +D.
- **Stage C 자산**([design-gc.md](design-gc.md) §10): vDriver repo HTAP 하니스 — sysbench `oltp_update_non_index`(48스레드 Zipfian 1.2 skew) + `BEGIN;SELECT;pg_sleep(60);COMMIT;` 60s long reader + version-chain 길이 샘플러. 지표 = **version-chain length CDF**(우리 vs vanilla InnoDB) + throughput.
- **이식 방향**: 우리 standalone 프로토타입에 writer N스레드 skew 업데이트 + reader snapshot 유지(LLT) + chain 길이 측정 하니스. (`chain_length(table,index)` 접근자 이미 있음.) baseline 대비 "LLT 하에서도 chain 짧게 유지"를 수치로 입증.
- **주의**: LLT는 **논리적 read-view는 길게, EBR Guard는 search 단위로 짧게**(reclaim 굶음 방지 — 이미 search가 traversal당 Guard라 충족; 하니스가 Guard를 60s 가로질러 쥐지 않게).
