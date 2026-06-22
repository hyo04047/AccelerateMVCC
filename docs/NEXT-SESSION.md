# 다음 세션 핸드오프 — Stage C 완료 + 보고서 + Stage D-0(InnoDB baseline) 완료, 다음은 D-1

> **새 세션은 이 파일을 가장 먼저 읽으세요.** 이전 대화 없이 그대로 이어가기 위한 핸드오프.
> 배경·설계근거 → [design-gc.md](design-gc.md)(§11 = stage C 결과)·[design-1c.md](design-1c.md) / **Stage D 설계·D-0 결과 → [design-D.md](design-D.md)** / 통합 보고서 → [REPORT.md](REPORT.md) / 상태·로드맵 → [README.md](README.md) / 이력 → [progress-log.md](progress-log.md) / 이슈 → [findings.md](findings.md)
> 갱신: 2026-06-21 (세션 4, **Stage C + 보고서 + D-0 완료** 후)

---

## ⏩ 재개 레시피 (새 세션은 이 순서로)
1. **맥락 복원**: 이 파일(§0→§D) → [design-D.md](design-D.md)(D 설계 + §7 D-0 baseline) → 필요 시 [progress-log.md](progress-log.md) 최신 2개 엔트리.
2. **검증(맹신 금지)**: `git log --oneline -8` + `git status` 확인 → (코어가 안 바뀌었으면) §1로 **20 correctness green** 1회 → **D-0 baseline 재현/이어가기**(§D 레시피).
3. **보고 후 시작**: 위 결과 짧게 보고 → **다음 = D-1**(accelerator를 InnoDB에 링크 + populate hook) 진행. ⚠️ D-1+는 InnoDB 소스 수술 = multi-session, 작게+체크포인트.
- 작업 방식: **작게 + 중간 체크포인트** / 설명은 **알고리즘·설계 레벨**(함수·코드명 덤프 X, 단 표준 용어는 영어 그대로). **성능이 목적 — correctness는 전제, no-crash가 아니라 visibility로 검증.**
- **프로젝트 성격**: 원래 2023 졸프였으나 지금은 **개인 프로젝트**(졸업용 아님). 단 성공 시 **논문급 보고서**(개인 이력/포폴용) 목표 — 가볍게 가지 말 것, 엄밀함 유지.

---

## D. Stage D 진행 (현재 위치 — D-4 ④ 읽기연결 중 4a·4b SHADOW 완료 = wrong-result 관문 통과, 다음 = 4c 캐싱 제외 게이트)
> **세션 6 갱신(2026-06-22) — D-4 ④ 4a+4b(SHADOW consult) 완료, 다음 = 4c**: "우리 in-memory cache가 디스크 MVCC를 consistent하게 반영하나"를 **실측으로 입증(hit_MISMATCH=0)**. 증분: **4a✅** InnoDB `ReadView::changes_visible` 4분기 정확 미러(`include/read_view_mirror.h`), search predicate 교체, 오프라인 단위테스트. **4b-0✅** 노드 키를 version_trx_id(=old DB_TRX_ID, 가시성 키)/writer_trx_id 분리(consume 버그 교정), epoch 배치 version 기준. **4b-1✅** ring/노드에 full-PK 식별 바이트(length-prefixed)+delete-mark + **캡처 윈도우 M1 수정**(rec_offs_size→`rec_offs_data_size`, data payload만). **4b-2✅** per-key contiguity bookkeeping(`interval_list_header`에 atomic contiguous_head_writer/suffix_min; per-key arrival은 row X-lock+FIFO ring으로 version 순서 → drop만이 gap, linkage로 검출). **4b-3a✅** cache-side `Accelerate_mvcc::consult()`(full-PK + changes_visible + contiguity 게이트, EBR Guard가 image 복사까지 span=M2) + 오프라인 6 테스트. **4b-3b✅** `row0vers.cc row_vers_build_for_consistent_read`에 SHADOW 배선(read0types 접근자 + top live-writer stash + 하단 byte 비교) — **calls=13000 hit_match=12998 hit_MISMATCH=0 noncontig=2**. **4b-3c✅** 적대적 매트릭스: 60s LLT(29998/30000, mismatch 0)·rollback(0 오답, 안전 MISS)·강제충돌(0 오답)·동시성 consult‖insert ASan/TSan clean·**오프라인 negative control**(full-PK OFF면 cross-row 오답 = 가드 진짜 작동; mysqld 충돌 음성대조는 contiguity 게이트가 먼저 MISS시켜 vacuous였음→오프라인으로 대체). standalone 32 tests Release/ASan/TSan green. 커밋 `1a79b83`(4a)·`dcbd81f`(4b-0)·`0ba4781`(4b-1)·`4cda4f5`(4b-2)·`3f4ac95`(4b-3a)·`5540ba7`(4b-3b)·`ed3f757`(4b-3c) 전부 push. **불변식 유지**: consult=LOCATOR/HINT, 모든 결과는 HIT(=vanilla byte 동일) 또는 MISS(full walk) — silent wrong result 구조적 불가. shadow=동작 불변(InnoDB가 자기 답 반환). **다음 = 4c**(캐싱 제외 게이트: off-page LOB `rec_offs_any_extern`·virtual column `table n_v_cols>0`·instant-DDL schema epoch·locking read `select_lock_type!=LOCK_NONE` 제외, committed만; sysbench 밖 일반 워크로드 안전) → **4d**(authoritative=walk skip·image 반환=실제 성능 이득) → ⑤ purge-view GC(메모리 bound, 1c-5 선행) → ⑥ 작은/큰 BP D-0 곡선 평탄화 측정. 설계 [design-D4b-shadow.md](design-D4b-shadow.md)(§3 배선·§8 리뷰 must-fix·§9 contiguity). 재현 `build_test_4b3.sh`(standalone 32)·`build_d4b3b.sh`(shadow mysqld)·`build_d4b3c.sh`(매트릭스)·`build_d4b1.sh`(populate). **아래 단락들(세션5·§D 본문)은 historical.**
>
> **세션 5 이어서 갱신(2026-06-22) — D-4 구현 ①②③ 완료, 다음 = ④**: ACID 적대적 검증 통과 후 walk 효율화 논의 결론을 **design-D §13에 D-4 정식 설계**로 박음 — locator가 아니라 **완성 행 image를 deadzone-짧은 lock-free chain에**(reader가 재구성 없이 image 반환; lock-free·epoch·deadzone·disk-based HTAP 틀 유지; 큰 BP=재구성 CPU·작은 BP=undo I/O+pollution 제거, amortization 불필요). **구현 ①✅(ring에 상한 image 칸·부분복사, standalone ASan/TSan torn=0) ②✅(populate hook이 `rec`+`rec_offs_size`로 행 image 캡처) ③✅(drainer가 `undo_entry_node`에 image 적재, dtor가 노드 수명과 함께 free)** — image가 **ring→노드까지 end-to-end**, write tput=vanilla(32k tps), 20 correctness green, enq==drained·dropped=0·누수/UAF 0. 커밋 `ebad8df`·`5057fea`·`a844e90`(push). **다음 = ④(읽기 연결, 가장 큼·correctness-critical)**: 4a `changes_visible` 정확 미러 → **4b consult를 `row0vers.cc`에 SHADOW 배선(consult image vs vanilla 재구성 byte-동일=mismatch 0 = 핵심 wrong-result 관문, 적대적 검증 권장)** → 4c 캐싱 제외(off-page LOB·virtual col·instant-DDL·locking read 제외, committed만, full PK, contiguity-to-head) → 4d authoritative → ⑤ purge-view GC(메모리 bound, 1c-5 선행) → ⑥ 작은/큰 BP에서 D-0 곡선 평탄화 측정. 상세 [design-D.md](design-D.md) §13(증분 상태)·§11·§12. 재현 `build_d2img.sh`(mysqld)·`build_d1b2a.sh`(ring)·`build_test_1c6.sh`(standalone)·`d0_bpsweep.sh`(BP sweep). **아래 두 단락(세션5 첫 갱신·§D 본문)은 historical.**
>
> **세션 5 갱신(2026-06-21)**: populate 경로(D-1a~D-1b-4) 완료 재검증 ✅ → **D-2/D-3 적대적 리뷰**(워크플로 42에이전트)에서 **consult-as-locator로는 D-0 평탄화 불가**(undo delta = top→down 순차 재구성) 확정 → **D-0 비용 분해 측정**으로 확증: 큰 BP는 CPU-bound version reconstruction(deep 0.49s, 물리 read 0, gdb로 `row_search_mvcc`→version build 40/40), 작은 BP(64M)는 **I/O-bound 75s/read 6만(~150×)**+pollution. → **방향 = version-level materialized cache**(재구성 결과 캐싱, deadzone 제외 working-set, ephemeral, miss→full walk fallback; 큰 BP=재구성 CPU·작은 BP=undo I/O+pollution 제거; DIVA류 "작은 메모리" 문제제기와 정합). ACID는 캐시가 authority 아님(committed past version immutable, isolation=changes_visible 재현+InnoDB 검증)으로 보존. **다음 = D-4 설계 전 ACID/correctness 적대적 검증** → 개정 증분 **D-2a(populate fix)→2b(changes_visible 미러)→2c(consult shadow, mismatch=0)→2d→D-3(purge-view GC)→D-4(cache)**. 상세 [design-D.md](design-D.md) §11·§12, 측정 스크립트 레포 밖 `d0_profile1/2.sh`·`d0_bpsweep.sh`, 리뷰 종합본 `d2_review_synth.txt`. **아래 §D 본문(D-1b까지)은 historical — 최신 방향은 이 단락.**
> 1차 목표 A+B+C는 완료(보고서 [REPORT.md](REPORT.md)). 설계·결과 상세는 [design-D.md](design-D.md).
- **결정 잠금**: MySQL **8.4.10 LTS** + **scoped PoC**(consult hook 1경로 + 측정) + **gcc-13**(gcc15 빌드 리스크 회피).
- **MySQL 빌드/실행 레시피**(WSL, 레포 밖 스크립트 재사용):
  - 소스 `~/mysql-server`(8.4 shallow clone), 빌드 `~/mysql-build`(RelWithDebInfo/gcc-13/ninja, ~11분). 재빌드: `build_d0b.sh`.
  - 기동 주의: root 운용 → mysqld에 **`--user=root`** 필수, source build → **`--lc-messages-dir=$HOME/mysql-build/share`**(언어 하위폴더의 부모), `--mysql-native-password=ON`(sysbench 인증). 데이터 `~/mysql-data`, 소켓 `~/mysql.sock`, 포트 3309.
  - baseline 재현/측정: `build_d0d.sh`(mysqld 기동 → OLTP churn + held-snapshot analytic scan latency). mysqld는 **한 스크립트 안에서만 살아있게**(wsl 호출 간 persist 안 됨).
- **D-0 baseline 결과**(= D가 이길 대상): held snapshot 하 1000행 analytic scan latency **0.7ms→1,355ms(~1,900×)** as OLTP churn deepens chains; history list 360→2.07M. **비교 지표 = held-snapshot analytic read latency vs churn**(throughput-only는 in-memory/단시간엔 신호 없음).
- **hook 지점**(MySQL 8.4 소스 확인됨): consult(D-2) = `storage/innobase/row/row0vers.cc:1249 row_vers_build_for_consistent_read`(row0sel.cc·row0pread.cc에서 호출), populate(D-1) = `storage/innobase/trx/trx0rec.cc:2117 trx_undo_report_row_operation`.
- **D-1 진행상황**: D-1a(배선)✅ → D-1b 적대적 리뷰(blocker 5→안전설계)✅ → D-1b-1(키 배선: PK 해시+prior trx_id, row-unique)✅ → D-1b-2a(lock-free MPMC ring `accel_ring.h` + standalone TSan/ASan PASS)✅ → **D-1b-2b(ring+drainer+생명주기를 mysqld에 배선)✅**. 통합 코드 repo `integration/innodb/`(`accel_hook.{h,cc}`, `accel_ring.h`, `d1b1_patch.pl`) + `accel_ring_test.cpp`. 스크립트 `build_d1a.sh`·`build_d1b1.sh`·`build_d1b2a.sh`·`build_d1b2b.sh`(레포 밖). MySQL 빌드 `~/mysql-build`(증분만).
  - **현재 동작**: hook(`trx0rec.cc` 성공 경로, MODIFY-op만)이 (table_id, pk_hash[FNV-1a], trx_id, old DB_TRX_ID, undo space/page/offset)를 **lock-free ring에 enqueue**(noexcept, full→drop). **off-latch drainer 스레드**가 pop+count(진짜 insert는 아직 X). 생명주기: `srv0start.cc` srv_start 끝 `accel_init()`·srv_shutdown 시작 `accel_shutdown()` + ready gate. 검증: enq==drained=1.8M, dropped=0, clean shutdown, 29.9k tps. ⚠️ 8.4: `rec_get_nth_field(index, rec, offsets, n, &len)`.
  - **D-1b-3a ✅**(빌드통합): accelerator(4 .cpp)+Kuku(kuku.cpp+blake2b.c+blake2xb.c)를 `INNOBASE_SOURCES`에 추가(절대경로)+include 경로(우리 include/·Kuku/src·생성 config.h `~/acc-build/Kuku/src`)+우리 소스 `-w`. accel_hook이 `accelerateMVCC.h` include + 전역 `Accelerate_mvcc(0,16)` 생성. 방법 [design-D.md](design-D.md) §10, 재현 `build_d1b3a.sh`.
  - **D-1b-3b ✅**(진짜 insert): drainer consume()가 저수준 `insert(table_id,pk_hash,trx_id,space,page,offset)`(단일 consumer=단일 mutator), ctor `kuku_log2` param(integration=16), GC off. 검증: 20 correctness green, drained==enq=1.34M·dropped=0·clean shutdown, **cur_key_chain_len=2616**(인덱스 실제 적재). 재현 `build_d1b3b.sh`/`build_d1b3b2.sh`.
  - **populate 경로(D-1b) 기능 완성** — AccelerateMVCC 인덱스가 mysqld 안에서 실제 InnoDB undo로 채워짐(latch 하 enqueue→off-latch single-consumer insert). memory는 GC off라 자람(의도).
- **다음 = D-1b-4(가벼운 하드닝)**: noexcept hook 감사(throwing path 없음 확인), accel=leaf-domain 불변식 주석/assert. → 그 후 **D-2(consult, 큰 새 단계 = 최종 payoff)**: `row0vers.cc:1249 row_vers_build_for_consistent_read`에서 accelerator로 가시 version 위치 점프. **반드시** InnoDB `ReadView`(m_low/up_limit_id, m_ids) 3-way `changes_visible`를 노드 DB_TRX_ID로 재구현(우리 search의 max-trx_id 루프 X), accelerator=LOCATOR(roll_ptr 반환→InnoDB 검증), **miss는 일반 chain walk fallback 필수**. 측정 = D-0 baseline(held-snapshot analytic 0.7ms→1.35s)을 평탄화하는지. consult 켜기 전 deadzone GC를 InnoDB purge view로 재구동(D-3)·rollback/purge 정합 필요(design-D §9 deferred). 안전 설계 [design-D.md](design-D.md) §9.

---

## 0. 30초 요약
- **프로젝트**: 디스크 DBMS(InnoDB) MVCC 가속용 in-memory 인덱스(Kuku hash → epoch 기반 interval list of undo 메타데이터 포인터) + deadzone GC. InnoDB undo는 안 건드리고 메타데이터 포인터만 compact 유지. **궁극 목적 = InnoDB HTAP/LLT 성능 향상.**
- **완료**: A ✅ · B ✅ · 동시성 1a·1b·1c ✅ · **Stage C ✅ (HTAP/long-txn 벤치, 1차 목표 A+B+C 결과물)**.
- **Stage C 헤드라인**(60s LLT, 6w/6r/1llt): **deadzone hot-chain max 155 vs tail-only(InnoDB식 purge) 845,977 (~5,500×)**, retire 22.4M vs 277, read throughput **1.36M/s vs 487/s (~2,800×)**. skew 0.8/1.2/1.6 전반 견고(~8,000×). FG cooperative unlink는 read-path +30%. 전 run **LLT visibility OK(inconsistencies=0)** + ASan/TSan clean. 상세 [design-gc.md](design-gc.md) §11.
- **현재**: 보고서([REPORT.md](REPORT.md)) 완료, **Stage D 진행 중 — D-0(vanilla baseline) ✅, 다음 = D-1**(위 §D). 1차 목표 A+B+C 달성, D는 최종(PoC).

---

## 1. 환경 & 빌드/테스트 레시피 (그대로 따라하면 됨)
- **WSL2 Ubuntu 26.04, root 운용**. 소스: `/mnt/c/Users/USER/projects/AccelerateMVCC`. 빌드: WSL 홈 `~/acc-build`(Release)·`~/acc-build-asan`·`~/acc-build-tsan`. gcc 15.2 / cmake 4.2 / 16코어.
- ⚠️ **PowerShell→wsl로 복잡한 bash 인라인 X**(따옴표·`$()` 깨짐). **스크립트 파일**로 쓰고 (예시 `/mnt/c/Users/USER/build_test_*.sh`·`stage_c_bench` 재현용 `build_test_c2.sh`·`build_test_c3.sh` 남아있음) `exec > /mnt/c/.../log 2>&1`로 받아 Read. **wsl 호출은 PowerShell 툴에서**. ⚠️ **백그라운드 detached(`nohup &`)는 WSL VM teardown으로 죽을 수 있음 → 긴 빌드는 포그라운드(블로킹) wsl 호출로.** CRLF 주의: 스크립트 실행 전 `sed -i 's/\r$//'`.
- **correctness(20개)**: `cmake -S <src> -B ~/acc-build -DCMAKE_BUILD_TYPE=Release` → `--target test_with_google` → 필터 `'MvccVisibility.*:GcDeadzone.*:GcEndToEnd.*:GcEbrIntegration.*:GcSharedDescriptor.*:GcRetireOnce.*:GcBackstopDrain.*:GcFgUnlink.*:GcScale.*'`. ASan: `-DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address"` + `ASAN_OPTIONS=detect_leaks=0`(구조상 의도된 누수). TSan: address→thread. (재사용: `build_test_1c6.sh`.)
- **Stage C 벤치**: `--target stage_c_bench`. key=value 인자: `records writers readers llt dur zipf sample_ms sample_keys llt_key seed fg tail warmup_ms csv`. **헤드라인 재현**(60s LLT): `stage_c_bench records=1000 writers=6 readers=6 llt=1 dur=60 sample_ms=500 sample_keys=8 tail=0 fg=1 csv=...`(deadzone) vs `tail=1`(InnoDB baseline) vs `fg=0`(BG-only). **controlled threading 필수**(writers+readers+llt+sampler+GC ≤ 코어, 아니면 chain length가 스케줄링 노이즈에 지배됨 — §3). 재현 스크립트 `build_test_c2.sh`(헤드라인)·`build_test_c3.sh`(correctness 회귀 + skew sweep).
- 동시성 디버깅: hang은 `timeout -s KILL N <bin>`(124/137=hang). gdb 설치됨. ASan 바이너리 `stdbuf` X.

---

## 2. Stage C — 완료 기록 (증분 C-0~C-3)
> **Stage C는 끝났다.** 상세는 [progress-log.md](progress-log.md) 세션 4·[design-gc.md](design-gc.md) §11. 요지:
- **하니스**(`stage_c_bench.cpp`): vDriver Figure-12 워크로드 이식 — Zipfian writer + OLTP point-reader(같은 skew) + 60s LLT(snapshot 길게·EBR Guard는 search당 짧게) + Guard-safe chain 샘플러(CSV). 신규 accessor `chain_length_guarded`(라이브 샘플링용, Guard판). 실험 토글: `set_gc_tail_only`(baseline = `can_pruning`을 zone 0만 = InnoDB tail purge), `set_fg_unlink_enabled`(FG 축, search의 prune-initiate 토글).
- **증분**: C-0(골격)→C-1a(OLTP reader, **가설 정정**: no-LLT에선 BG만으로 유계라 reader 기여 X)→C-1b(60s LLT, visibility oracle)→C-2(헤드라인 3-run)→C-3(skew sweep robustness).
- **부수 수정**: BG GC stop-responsiveness(catch-up 루프가 `gc_stop_` 확인 — tail-only backlog에서 join 무한대기 버그) — findings #14. 20 correctness 회귀 green 확인.
- **결과**(§0 헤드라인 + design-gc §11 표): deadzone가 LLT 하 in-middle reclaim으로 chain 유계(max ~155), tail-only는 폭주(~846k), read tput ~2,800× 우위. FG는 read-path +30%. correctness는 visibility로 검증.

---

## 3. 결정 잠금 (재논의 금지 — 근거는 design-gc.md §11 / design-1c.md)
- **Stage C baseline = 프로토타입 내 tail-only GC 모드**(`set_gc_tail_only`). standalone이라 실 InnoDB 대신 InnoDB purge(global-min 아래만 회수)를 모델링. 실 MySQL+sysbench 비교는 **Stage D** 영역.
- **측정 방법론**(필수): ① controlled threading(스레드 ≤ 코어) — 아니면 chain length가 BG-GC 스케줄링에 지배됨(알고리즘 신호 아님). ② warm-up 제외(`warmup_ms`, GC warm-up early-return이 짧은 런 오염). ③ Guard-safe 샘플러. ④ **deadzone/FG 신호는 LLT 시나리오 고유**(no-LLT는 BG-only로도 유계라 비교 무의미).
- **correctness = visibility로 검증**(no-crash 아님): LLT visibility oracle(자기 visible version 불변) + conservation(detached==retired) + ASan/TSan.
- (1c에서 잠금) deadzone = vDriver Theorem 3.1, tight bounds(`[min_trx_id, superseded_ts]`), GC = 단일 BG 액터, hot path lock-free + marked pointer + per-traversal EBR. provenance = vDriver 파생(PostgreSQL License 표기).

## 4. 후속/평가 후보 (지금 건드리지 말 것)
- design-gc §9.3: list→DIVA interval tree(LLT 하 chain을 log로 bound), tagged-pointer reclamation, hot/cold/LLT classification, multi-granularity 노드.
- 잔여 perf 미세(1c): cold record head wrapper가 bucket 유지 → long_live_epochs가 live-bucket 수만큼 유지(correctness 아님).
- Stage C 확장(원하면): read latency 분포(현재는 throughput), epoch 수/EPOCH_SIZE knob 영향, CDF 차트를 보고서 figure로.

## 5. 현재 repo 상태
- branch **master**, working tree **clean**, **origin/master까지 push 완료**. **최신 커밋 = Stage C** (feat: 벤치+토글+GC fix / docs: 결과+핸드오프). `git log --oneline -8`로 확인.
- Stage C 신규/변경: `stage_c_bench.cpp`(신규 벤치), `include/accelerateMVCC.h`(`chain_length_guarded`·`set_fg_unlink_enabled`·`set_gc_tail_only`·GC stop-fix), `include/accelerateMVCC.cpp`(search FG 토글), `include/epoch_table.h`(`set_gc_tail_only`+`can_pruning` tail-only 제한), `CMakeLists.txt`(`stage_c_bench` 타깃). docs: README·progress-log·findings·design-gc(§11)·이 파일.
- **레포 밖 자산**(WSL/Windows, git 추적 X): `/mnt/c/Users/USER/build_test_c*.sh`·`sweep_c3.sh`·`cdf.sh`·`stage_c_*.csv`·`*.log`. 재현 시 재사용.

## 6. 로드맵 위치 — 1차 목표 A+B+C 달성, 다음은 D(최종) 또는 보고서
A ✅ → B ✅ → 동시성(1a ✅→1b ✅→1c ✅) → **C ✅(HTAP/long-txn 벤치)** → 보고서 ✅ → **D(InnoDB 통합) 진행 중: D-0 ✅ → D-1 다음**(위 §D / [design-D.md](design-D.md) §4).
- **D 자산/방향**(design-gc §6 vDriver 매핑): 실제 InnoDB 소스에 가속 인덱스 연결(trx_sys active list, undo 메타데이터 포인터), sysbench HTAP로 vanilla MySQL 대비 측정. 규모 큼 — 착수 전 사용자와 범위 합의.
- **보고서 방향**: A~C를 논문급으로(문제→설계(vDriver 계보)→동시성 하드닝→Stage C 결과/CDF). 차트·표는 design-gc §11 + 생성한 CDF figure 재사용.
- **다음 세션은 D vs 보고서 중 무엇부터 할지 사용자에게 물어볼 것.**
