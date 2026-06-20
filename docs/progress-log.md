# 진행 로그

진행 상황을 세션별로 기록. 최신이 위.

---

## 2026-06-21 — 세션 4 (이어서): Stage D 착수 — D-0(InnoDB baseline) ✅

> Stage C lock-in(커밋·push) 후 사용자 요청으로 **A~C 논문급 보고서**(`docs/REPORT.md`) 작성·커밋, 이어서 **Stage D(InnoDB 실통합)** 착수. 설계는 [design-D.md](design-D.md).

**D 설계**: hook 3지점(populate=undo create, consult=consistent read, deadzone↔trx_sys 동기화). MySQL 소스에서 hook 함수 위치 확인 — consult=`row0vers.cc:1249 row_vers_build_for_consistent_read`, populate=`trx0rec.cc:2117 trx_undo_report_row_operation`. 결정: **MySQL 8.4.10 LTS + scoped PoC + gcc-13**(gcc15 빌드 리스크 회피).

**D-0 ✅ (vanilla baseline)**: MySQL 8.4.10 RelWithDebInfo를 gcc-13/ninja로 빌드(11분, 에러 0) → mysqld 기동 + sysbench 1.0.20. **발견**: OLTP throughput은 LLT에 거의 불변(1,867→1,882 tps, 30s/in-memory)이나 **history list length 360→56,752 폭증**(purge가 LLT에 막힘 재현). **진짜 비용은 analytic read** — held snapshot 하 `SELECT SUM(LENGTH(c))`(1000행 scan)을 OLTP churn 중 측정하니 latency **0.7ms→1,355ms (~1,900×)** 증가(history list 2.07M). **baseline metric 확정 = held-snapshot analytic read latency vs churn**(consult hook D-2이 평탄화할 대상). throughput-only는 단시간/in-memory엔 신호 안 남. 상세·재현 [design-D.md](design-D.md) §7.

**→ 다음 = D-1**(accelerator를 InnoDB에 링크 + populate hook) — InnoDB 소스 수술, multi-session.

---

## 2026-06-20 — 세션 4: Stage C (HTAP/long-txn 벤치) — 1차 목표 A+B+C 결과 산출 ✅

> **프로젝트 성격 정정**: 원래 2023 졸업프로젝트였으나 지금은 **개인 프로젝트**(졸업용 아님). 단, 성공 시 개인 이력/포폴용 **논문급 보고서**로 정리 목표라 엄밀함은 그대로.

**재개 검증**: HEAD=`73f6608`(1c 완료, clean, origin 동기화) 확인 → 20 correctness Release/ASan/TSan green 재확인.

**하니스 이식**: design-gc §10의 vDriver Figure-12 워크로드를 standalone 프로토타입으로. 신규 `stage_c_bench.cpp`(key=value args) — Zipfian(s) writer + OLTP point-reader(같은 skew) + 60s LLT(snapshot은 길게, EBR Guard는 search당 짧게) + Guard-safe chain 샘플러(CSV). 신규 accessor `chain_length_guarded`(기존 quiescent-only `chain_length`의 Guard판 — 라이브 샘플링용). 실험 토글 2개: `set_gc_tail_only`(can_pruning을 zone 0만 = InnoDB tail purge 모델) / `set_fg_unlink_enabled`(search의 FG prune-initiate 토글, marked-skip helping은 유지). 지표 = version-chain length CDF + throughput + LLT visibility oracle.

**증분 C-0 (골격) ✅**: Zipfian writer + 샘플러 + CSV(LLT 없이). 3 config 빌드·실행, conservation 정확 일치, ASan/TSan clean. **발견**: writer-only에서 hot 체인이 선형 폭주(~60k)할 때가 있음 → BG-only GC의 version-chain unlink가 **O(chain)**(header forward-scan)이라 high write rate에서 못 따라잡음. O(1) 경로는 **FG cooperative unlink**(reader가 carried pred_next로 splice)뿐 → reader 필요.

**증분 C-1a (OLTP reader) ✅ + 가설 정정**: reader 추가가 FG unlink로 hot 체인을 줄일 것으로 예상했으나 **데이터가 반증**. probe(8w/0r ×3, 8w/8r ×3, 6w/6r, 4w/4r)로 확인한 진짜 원인: **chain length는 no-LLT에선 BG-GC 스케줄링/CPU에 지배됨** — oversubscribe(스레드>코어)하면 BG GC가 굶어 deadzone publish/retire 급감(스파이크), non-oversubscribed면 양쪽 다 안정·유계. **no-LLT에선 reader가 체인을 못 줄임**(LLT 없으면 newest 아래 전부 dead → BG만으로도 CPU만 있으면 이미 짧음). C-1a의 실제 수확 = **multi-unlinker correctness**(reader 8개 동시 FG unlink에서 ASan UAF/double-free 0, TSan race 0) + 방법론(controlled threading ≤ cores−2 필수, 경량 sampling).

**증분 C-1b (60s LLT) ✅**: controlled threading(6w/6r/1llt=15≤16). **deadzone의 진짜 가치는 LLT 시나리오 고유** — LLT가 global-min을 pin하면 tail purge는 in-middle을 못 줄임. Release 30s: **LLT visibility OK**(139.7M searches, inconsistencies=0) + hot 체인 max=155(17.7M writes에도 유계, tight-bound deadzone의 in-middle reclaim) + reclaim 진행(retired 10M, conservation 일치). ASan/TSan(8s) 동일하게 clean·visibility OK. **correctness를 no-crash가 아니라 visibility로 검증**(메모리 규칙).

**증분 C-2 (헤드라인) ✅**: 60s LLT, 6w/6r/1llt 3-run matrix. ① deadzone+FG / ② deadzone BG-only / ③ tail-only+FG.
- **헤드라인 (① vs ③)**: deadzone hot-chain **max 155** vs tail-only **845,977** (~5,500×; p50 15 vs 258,632 ~17,000×). 메커니즘 확증 — 같은 60s에 retire **22.4M vs 277**(tail purge는 LLT 아래만 회수 가능 → 거의 못 함). HTAP 비용은 read에: tail-only read tput **487/s** vs deadzone **1.36M/s**(~2,800×; tail-only는 write tput만 1.38M>649k/s — GC를 안 해서, 전형적 HTAP 함정).
- **FG 증분 (① vs ②, 부하 고정·토글만)**: FG가 chain 분포 하향(p50 15 vs 41, p99 45 vs 84) + read tput +30%(1.36M vs 1.04M reads/s) — reader가 traversal 중 dead epoch 떼어 search가 빨라짐. max는 noise 내(155 vs 114, worst-case는 BG deadzone가 받침).
- 전 run **LLT visibility OK**(tail-only 폭주 baseline조차 자기 version 정확히 봄), 새 토글 경로 ASan/TSan clean.

**GC stop-responsiveness 수정 (C-3 중 발견·수정) ✅**: tail-only baseline은 거의 prune 안 해 epoch/bucket 무한 누적 → BG GC의 boundary catch-up for-loop가 `gc_stop_`을 안 봐서, 큰 backlog에서 `stop_background_gc().join()`이 사실상 안 끝남(무한 대기). catch-up 루프가 매 iteration `gc_stop_`을 확인하게 수정(종료 중엔 남은 drain 포기가 안전 — 더 돌 GC 없음). 실제 shutdown robustness 개선이라 유지. 수정 후 20 correctness Release/ASan/TSan 재검증 green(기존 동작 불변), GcScale는 stop 후 run_gc_once로 드레인하므로 conservation 영향 없음.

**증분 C-3 (robustness sweep) ✅**: skew s∈{0.8,1.2,1.6} × {deadzone, tail-only}, 20s, **warm-up 제외**(GC warm-up early-return이 짧은 런 percentile 오염 → `warmup_ms` 도입, CSV는 전체 보존·요약만 steady-state). deadzone max **38/40/41**(skew 무관 안정) vs tail-only **308k/322k/335k** → 우위 ~8,000× 견고. 전 12런 visibility OK·hang 0(각 런 `timeout -s KILL` 가드). (앞서 본 deadzone 78k "스파이크"는 warm-up 측정 아티팩트였고 제외하니 사라짐 = 알고리즘 문제 아님 확인.) CDF 차트 생성.

**→ Stage C 완료 (C-0~C-3).** 1차 목표 A+B+C의 결과물 확보: **LLT 하 deadzone in-middle reclaim이 version-chain을 유계로 유지(max ~155) vs InnoDB식 tail purge 폭주(~846k), read tput ~2,800× 우위**, FG cooperative unlink는 read-path 추가 개선(+30%), correctness는 visibility로 검증. 빌드/실행 자산 `/mnt/c/Users/USER/build_test_c*.sh`·`stage_c_*.csv`(레포 밖). **다음 = D(InnoDB 통합, 최종) 또는 보고서 정리** — 상세 [NEXT-SESSION.md](NEXT-SESSION.md).

---

## 2026-06-19 — 세션 3: Step 1c 설계(적대적 하드닝) + 증분 1c-0 ✅

**재개 검증**: HEAD=`08d70b6`(1b 완료+적대적 리뷰+push, clean) 확인 → Release/ASan/TSan 9개 전부 green 재확인(헤더 변경 캐시 무효화 후 재빌드). 1b 상태 무결.

**방향 결정(사용자)**: 다음은 **1c(FG 협조 unlink) 풀스코프**. "FG 논리마킹만 vs 물리 unlink까지" 물었으나 사용자가 **풀스코프**(물리 unlink+retire, 보류 #1·#2·#5 흡수) 지정 — "성능 향상에 필요하면 범위 깎지 말 것"([[scope-prefer-full-for-performance]] 메모리화). 추가로 **최우선 목적 = InnoDB HTAP 성능 향상**(correctness는 전제, 목표 아님)임을 재강조받아 설계 평가 기준을 성능 기여도로.

**설계 패스(워크플로 9에이전트: 위험요소 4축 병렬 → 종합 → 적대적 검증 4관점)**: 종합안을 검증 4관점 **모두 holds=false**로 깸. 단 핵심(상태도장 retire-once / 디스크립터 EBR 수명 / 단조 trx-id→과청소 없음)은 **못 깸=건전**. 깨진 건 전부 가장자리 → 순서·불변식만 조여 닫음. 상세 [design-1c.md](design-1c.md).
- **헤드라인 버그(3관점 독립 지적)**: BG head-prune이 `header->next` CAS로만 조율하는데 insert의 in-place append는 그 포인터를 안 쓰고 record mutex만 잡음(BG는 mutex 안 잡음) → head retire와 append 무동기 → write-after-free+insert 유실. 수정: head는 '더 이상 head 아님'에만 prune(#5를 deadness 아닌 demote에 게이트)+insert head 접근 EBR Guard+head writer를 insert/BG 2자로 제한.
- **재배열**: 전부-CAS·전버킷 backstop을 FG 떼기보다 **앞**으로, retire 권한 상태도장 1곳 일원화, long_live_epochs tombstone화, LLT는 짧은 per-search Guard.

**증분 1c-0 ✅** EBR **slot lease**(보류 #1 흡수): creation-order round-robin(lifetime 스레드 256개에 assert) → **per-thread 슬롯 임대**(전역 풀, 첫 Guard에 획득·thread 종료 시 반납 → *동시생존* 스레드 기준). pool 고갈(>256 동시) 시 **보수적 overflow pin**(slotless reader가 announce 전에 floor를 자기 entry epoch 이하로 CAS-낮춤, seq_cst, no-reset). 신규 테스트 2개(순차 churn 517 / 동시 272→overflow 16) + 기존 9개, Release/ASan(UAF 0)/TSan(race 0) green. 인덱스 동작 변경 0. 커밋 `30d3a83`/`7a1f5e0`.

**증분 1c-1 ✅** **공유 deadzone descriptor publish + consume(판정만)**: BG가 매 사이클 만들던 deadzone을 `delete` 대신 **원자 publish(exchange)** 하고 옛 것을 **EBR로 retire**(reader가 traversal Guard 중 들고 있을 수 있어). reader(search)는 그 descriptor를 **자기 Guard 안에서 load**해 각 epoch의 dead 여부를 **판정만**(아직 unlink X — 1c-4 hook). 판정 결과는 `coop_dead_seen` 메트릭으로 카운트(= reader가 지나친 dead epoch 수 = chain bloat 프록시, 성능 지표). 안전: descriptor를 epoch_node와 **같은 reservation**이 pin → BG가 retire해도 reader 밑에서 free 안 됨. nominal epoch window라 append가 verdict를 못 넓힘(과청소 X). 신규 테스트: **staleness oracle**(옛 descriptor가 prune하는 epoch은 현재 descriptor도 prune = 단조 trx-id→dead zone만 성장, 결정적) + concurrent consume(coop_dead_seen>0 + ASan/TSan으로 publish/retire 수명 검증). 11개 Release/ASan(UAF 0)/TSan(race 0) green. 기존 동작 불변(GC sweep 동일, 가시성 동일). (참고: `can_pruning`의 pre-existing sign-compare 경고는 내 변경 아님, 미수정 보류.)

**증분 1c-2 ✅** **retire-once state machine + version-chain 전부 CAS (아직 BG 단독 unlinker)**: epoch_node에 `state`(LIVE→CHAIN_DETACHED→RETIRED). version chain에서 splice한 쪽이 `state` LIVE→CHAIN_DETACHED CAS-claim 후 멈춤(retire X); **유일한 retire 권한 = `retire_epoch_once`**(`state.exchange(RETIRED)` 게이트, BG만). version chain 물리 splice를 plain store→**Harris CAS**(`unlink_epoch_from_chain`: header에서 predecessor forward-scan + CAS, race 시 restart)로(1c-4 multi-unlinker 대비). wrapper splice는 plain store 유지(BG 단독, disjoint bucket). conservation 카운터(detached/retired)로 "detached node는 정확히 한 번 retire" 검증. 신규 테스트 `GcRetireOnce`(concurrent + single-thread, held-reader로 deadzone 비움 방지) 2개 + 기존 11개 = **13개 Release/ASan(double-free 0)/TSan(race 0) green**. 가시성·GC 동작 불변.
- **적대적 코드리뷰(reviewer 3)**: 1c-2 코드 정확 확인(insert/search 못 깸, `unlink_epoch_from_chain` 1c-4용까지 정확). forward-looking 제약 2건 문서화([design-1c.md](design-1c.md) §7) — ① 1c-3 drain은 단일 swept-wrapper 소유권 *transfer*(gate가 `en` 안에 있어 free 후 재접근 시 UAF) ② 1c-5 전 insert head-prepend를 CAS로. 가짜 ">1 wrapper 안전" 주석 정정.

**증분 1c-3 ✅** **full-bucket backstop sweep + dummy-overflow drain (#2 흡수, 전부 BG 단독)**: ① **tombstone** — 드레인된 bucket을 `erase`(인덱스 시프트→윈도 산술 깨짐) 대신 nullptr로(long_live_epochs push-only 유지, sweep은 null skip). ② **backstop** — windowed sweep은 bucket을 1회만 보므로 그 뒤에 죽는 epoch(또는 1c-4에서 FG가 cold bucket에 detach한 노드)이 strand됨 → 낮은 cadence(매 4 cycle)로 전 live bucket 재방문. 대부분 empty/tombstone라 O(1) skip. ③ **dummy drain** — dummy-overflow를 single-head **Treiber stack**으로 리팩터(insert=push, BG=exchange로 통째 detach), drain이 dead orphan은 detach+retire, live는 re-queue. orphan wrapper는 그 epoch의 **유일한** wrapper라 retire가 곧 단일 소유권 — 리뷰 제약대로 **transfer(복제 X)**. prune 로직을 `detach_and_retire_epoch`/`wrapper_prunable`/`sweep_bucket`/`drain_dummy` 헬퍼로 공통화. 신규 테스트 `GcBackstopDrain`(4 writer가 bucket-swap race로 dummy 적재 → conservation detached==retired + `dummy_pending` 유계) + 기존 13개 = **14개 Release/ASan(UAF/double-free 0)/TSan(race 0) green**. 새 경고 0(can_pruning sign-compare는 pre-existing). (perf 미세 항목: tombstone vector가 무한 성장 — 1c-6에서 compaction/별도 pending list로.)

**증분 1c-4 ✅** **FG cooperative unlink (payload — version chain이 처음으로 multi-unlinker)**: reader(search)가 dead **non-head** epoch을 직접 mark + best-effort O(1) CAS-splice(carried `pred_next`, retry 없음 → livelock 없음, 실패 시 BG backstop이 처리). **retire는 BG 단독**(FG는 state 안 건드림; BG가 descriptor-dead로 retire, conservation 유지). **head는 항상 scan**(never pruned → reader의 visible-latest 안 놓침). 메트릭 `coop_dead_seen`, 테스트용 `chain_length`. 신규 테스트 `GcFgUnlink`(visibility oracle `RegisteredReaderResultStable` + hot-record reader‖reader/reader‖BG splice race `HotRecordCoopUnlinkShrinksChain`).
- **적대적 코드리뷰(reviewer 3) → blocker 2건 수정**(reviewer 3은 retire/UAF/conservation 못 깸 = 건전). [design-1c.md](design-1c.md) §8:
  - **chain corruption (stale successor)**: FG splice가 mark 전에 읽은 successor를 써서, 동시 unlinker가 next를 바꾸면 live node drop + detached node 되살림(UAF). 수정: set_mark 후 re-load, marked일 때만 frozen successor로 splice.
  - **deadzone over-prune (tight bounds, 깊은 correctness)**: nominal epoch 범위를 xmax로 써서 reader/LLT가 보는 version을 dead로 오판(pre-existing BG 잠복, 1c-4가 증폭 → LLT correctness 깨짐). 수정: `epoch_node.superseded_ts`(insert prepend가 옛 head에 기록) + `can_prune_epoch`이 실제 `[min_trx_id, superseded_ts]`로 판정(FG·BG 공통 경로 → 한 곳 수정). **고치기 전 깨지는 테스트 먼저**(`GcDeadzone.TightBoundDoesNotOverPruneNeededVersion`: nominal FAIL → tight PASS)로 경험적 확인. = design-gc §8.1을 perf 개선에서 **correctness 필수**로 격상.
- **17개 Release/ASan(UAF/double-free 0)/TSan(race 0) green.** 새 경고 0.

**증분 1c-5 — 불필요(tight bounds가 #5를 해소) ✅**: head epoch은 record의 **현재 값**이라 아직 안 덮임(`superseded_ts=∞`) → tight bounds에서 **절대 dead 판정 안 됨**. 즉 GC가 head를 올바르게 보존하고 나머지만 prune — "cold dead head"는 nominal over-pruning이 살아있는 head를 dead로 오판한 artifact였고, 1c-4 tight bounds가 그 오판을 없애 #5 자체가 사라짐. design §3의 head-prune vs append headline 동시성 문제, insert head-prepend CAS 선행 요구, BG single-attempt-defer 다 같이 dissolve(head-prune이 없으니까). 확인 테스트 `GcDeadzone.HeadEpochIsNeverPruned`(head: nominal range가 dead zone 깊숙이 있어도 superseded_ts=∞라 prunable 아님). 18개 green. (잔여: cold record의 head wrapper가 bucket을 살려둬 long_live_epochs가 천천히 자라는 건 **correctness 아니라 perf** — 1c-6 tombstone 압축으로.)

**증분 1c-6 ✅ (1c 마감)**: ① **long_live_epochs compaction** — tombstone(회수된 bucket nullptr)을 backstop cadence마다 erase해 vector가 *all-buckets-ever*가 아니라 *live bucket* 수를 추적. backstop(전-bucket scan)이 correctness를 받쳐주고 retire-once가 idempotent라, windowed sweep의 size-relative 인덱스가 흔들려도 안전(최악 = bucket이 windowed→backstop 경로로 이동). ② LLT 짧은 Guard·FG dead-scan skip은 이미 충족(search가 traversal당 Guard; 1c-4가 dead non-head scan skip). 신규 테스트 `GcScale`: HighConcurrencySkewedWorkload(16스레드/400k write/skew → conservation + chain<256 + `long_live_size`<2000[compaction 확인] + ASan/TSan clean) + LongLivedReaderConsistentUnderHeavyGc(LLT가 heavy GC‖churn 중에도 자기 visible version 계속 봄[tight bounds] + reclaim 진행). **20개 Release/ASan(UAF/double-free 0)/TSan(race 0) green.** 새 경고 0.

**→ Stage 1c 완료 (1c-0 ~ 1c-6, 1c-5 dissolved).** FG cooperative unlink + 전용 BG GC + EBR 회수 + tight-bound deadzone이 multi-writer‖multi-reader-unlink‖BG GC 하에서 ASan/TSan/진행성 검증됨. stage C 전 보류 3건 모두 해소. 적대적 코드리뷰 2회(1c-2/1c-4)가 blocker 3건(stale-successor chain corruption + tight-bounds LLT correctness) 잡음.

**다음 = Stage C (HTAP/long-txn 벤치)** — 1차 목표(A+B+C)의 실제 결과물: vDriver Zipfian+60s LLT 하니스 이식, version-chain length CDF vs baseline. (잔여 perf 후보: design-gc §9.3 — hot/cold/LLT classification, list→interval tree 등은 C 결과로 우선순위 판단.)

---

## 2026-06-18 — 세션 2 (이어서): Step 1b 설계 패스 + 증분 0·1

**설계 패스(워크플로 9에이전트: 병렬 하자드 매핑 → 설계 합성 → 적대적 검증 3관점 → 정리)**: marked-pointer(Harris) 도입안 확정. 적대적 검증이 잡은 핵심 — mark 비트만으론 부족: insert도 EBR Guard 필요(ABA/UAF), "기존 epoch에 undo 추가" 경로 쓰기 전 재검증 + count/min/max 원자화, GC의 `prev` deref는 UAF, undo 체인 누수, **reclaim 동시진입 이중free**, retire stamp는 물리 unlink CAS 이후.

**중요 정정(사용자 지적)**: "동시 GC"는 프로토타입이 GC를 트랜잭션 스레드에서 **인라인 트리거**(`trx_id%2500==0`)하던 부작용 — 설계가 아님. 설계대로 **GC를 단일 BG GC 액터(전용 스레드)로** 만들고 인라인 트리거 제거 → 동시 GC 없음·GC lock 불필요(InnoDB purge/vDriver Cutter 정석). FG 협조 unlink는 1c(marked-pointer 토대 위 additive). GC가 레코드 `header`에 못 닿는 구조라 head-prune 시 `header->next` dangling(잠복버그) → epoch_node에 `header` 역포인터로 해결(증분 2).

**증분 0 ✅** `include/marked_ptr.h`(Harris mark-bit 헬퍼: pack/ptr_of/mark_of/cas/set_mark) + 정렬 static_assert + 단위테스트. 리스트 미배선=동작 변경 0. Release/ASan green. 커밋 `0e98a4c`.
**증분 1 ✅** EBR retire를 다중-producer(lock-free Treiber 스택)로, reclaim을 try-lock 단일소비자로(consumer-local survivors). 적대적 검증이 잡은 reclaim 동시진입 이중free 제거. 4 retirer + 동시 reclaim + 3 reader 스트레스 — Release/ASan(누수 탐지 포함)/TSan green, deleter 정확히 1회. 커밋 `63ef424`.

**증분 2 ✅**(`ecd46a4`) 인터벌 리스트 Harris 전환: `epoch_node.next`/`header.next`를 `MarkedPtr`로, `prev` 제거(forward-only), `header` 역포인터 추가(GC가 header에서 predecessor forward-scan + head-prune dangling 수리), GC unlink mark→splice, search marked skip, undo 체인 단일 deleter(누수 해소). 8개 회귀 Release/ASan green.
**증분 3 ✅**(`c7993cd`) wrapper 리스트 Harris 전환: `epoch_node_wrapper.next` `MarkedPtr`, GC splice mark→store, insert head-insert MarkedPtr CAS. 8개 회귀 Release/ASan/TSan(reader-search‖GC-unlink) green.

**증분 4 ✅**(`9fcac82`) 전용 BG GC 스레드(`Accelerate_mvcc`가 start/stop 수명관리, dtor join) + 인라인 GC 트리거 제거(단일 GC 액터 → "동시 GC" 부작용 소멸) + `run_gc_once`(결정적). **GC가 head epoch skip** → 단일 writer에서 insert‖GC가 disjoint word만 만져 insert 하드닝 불필요. 테스트가 진짜 BG GC ‖ writer ‖ readers로 동작: 8개 Release(hang 0)/ASan(UAF 0)/TSan(race 0) green. **단일-writer 1b 동시성 검증 완료.**

**증분 5 ✅**(`b15d60e`) 다중 writer 검증(production 변경 0): `ConcurrentWritersReadersBgGc`(4 writer+3 reader+BG GC, 8레코드 12만 insert) Release/ASan/TSan green. 큰 하드닝 불필요 — 같은-레코드 insert는 레코드 락이 직렬화(=정상 MVCC), 다른-레코드 disjoint, wrapper는 Treiber CAS, insert‖GC는 GC-skips-head 커버.

**→ Step 1b 완료**: lock-free read + 전용 BG GC 스레드 + 동시 multi-writer가 marked-pointer 버전/wrapper 리스트 + EBR 회수 위에서 ASan(UAF 0)/TSan(race 0)/진행성 검증.

**적대적 코드 리뷰 ✅**(`49f28b7`, 워크플로 57에이전트: 5관점 attack→finding별 verify→종합; 51발견 중 28 false-positive 기각 = 핵심 설계 건전 확인): 잠복결함 8건 중 **값싼 7건 수정**(EBR slot interim assert·dummy ctor 99누수·insert Guard·GC cadence catch-up·min_reservation seq_cst·thread 예외안전·run_gc_once 가드, Release/ASan/TSan 9개 green 유지). **🔴 stage C 전 필수 3건 문서화**: EBR slot lease / dummy-overflow consumer / cold-head prune (findings.md). **다음 = C(벤치, 권장) 또는 1c** — 상세 [NEXT-SESSION.md](NEXT-SESSION.md) §2·§6.

---

## 2026-06-18 — 세션 2: EBR 통합 (Step 1a-ii) ✅ + read-view 평탄화 fix

**구현(1a-ii) ✅**: 검증된 per-traversal EBR을 GC·search에 통합. GC가 prune한 노드를 inline `delete` 대신 `EpochReclaimer`로 **retire**(epoch_node + 내부 wrapper/table-node), `search`의 interval-list 순회를 **`Guard`**로 보호, `garbage_collect` 진입부에서 **`reclaim`**. 단일 unlinker(=GC 한 스레드)·EBR 단일 producer 전제 유지. 커밋 `e1a45c4`.

**도중 발견·해결: read-view 무한중첩 hang (정공법 평탄화)** — `trx_t.active_trx_list`가 `std::vector<trx_t>`(값) 재귀라, 스냅샷이 다른 트랜잭션의 스냅샷을 통째 복사 → 중첩이 세대마다 누적. 단일 활성 트랜잭션(B단계까지의 모든 테스트)에선 스냅샷이 비어 무해했으나, **동시 트랜잭션이 겹치면 `copy_active_trx_list()`가 무한 폭발 → hang**(gdb로 전 스레드가 재귀 `vector<trx_t>` 복사에 200+ 프레임 갇힘 확인). ASan은 메모리 오류 0건(크래시 아님) → hang 확정. deadzone는 read-view에서 2단계(활성 trx + 각자의 활성 id)만 소비하므로 **read-view를 평탄한 `std::vector<uint64_t>`로** 교체(`active_trx_ids`), 복사 O(N)·비재귀. EBR 통합의 **선행조건**. 커밋 `0797855`. (이 hang은 EBR과 무관한 트랜잭션 레이어 결함이었고, EBR은 죄 없음.)

**검증**: 신규 `GcEbrIntegration.SingleThread` + `ConcurrentReaders`(writer 1=GC + reader 4, guarded search 루프) — Release + **ASan(UAF 0) + TSan(race 0) 클린**, 기존 6개 포함 총 8개 통과. 도구: gdb 설치(WSL, 스택 덤프로 hang 원인 규명).

**커밋 분리**: `0797855`(평탄화 fix) → `e1a45c4`(EBR 통합). 성격이 달라 이력상 분리. push는 미실행.

**다음**: Step 1b — 동시 unlink 일관성용 **marked pointer**(Harris) → 다중 unlinker/협조적 FG unlink 가능하게(현재는 단일 unlinker 한정).

---

## 2026-06-18 — 세션 1 (이어서): 동시성 설계 정렬 + EBR 프리미티브

**방향**: 다음은 **동시성 하드닝**(lock-free epoch-list가 멀티스레드 전제였음). 구현 전 논문·설계를 1차 자료로 정렬.

**논의·확정 (요지, 상세 [design-gc.md](design-gc.md))**:
- FG/BG GC = FG 협조 unlink→trash, BG reclaim (6·7월 deck 원문 확인).
- lock-free 리스트에서 단일 CAS로도 노드 유실 가능(Herlihy&Shavit "Problem" 슬라이드 — 강의 C++) → 동시 unlink엔 **marked pointer** 필요.
- reclamation grace: **per-transaction(active-list) 폐기 → per-traversal EBR**. (per-transaction은 LLT가 회수를 막아 deadzone 취지를 깸. 논리=deadzone / 물리=EBR, 시간척도 다름.)
- deadzone = vDriver **Theorem 3.1** 충실; `can_pruning` = vDriver `IsInDeadZone`(`xmin>left && xmax<right`) **동일 공식**(코드 레벨 확정). epoch=vDriver segment. provenance=**vDriver 파생** 확정.
- 개선 latitude 수용(tight min/max 경계, hot/cold/LLT 분류 등 후속 후보).

**구현(1a 첫 조각) ✅**: per-traversal EBR 프리미티브 [`include/epoch_reclaimer.h`](../include/epoch_reclaimer.h) + `ebr_test`(8-reader 스트레스) — **ASan(UAF 0)/TSan(race 0) 클린.** 커밋 250838a.

**논문**: vDriver(LLT) 직접 정독 완료(문제의식+알고리즘). DIVA + One-shot GC는 백그라운드 워크플로 정독 중(→ design-gc §9 종합 추가 예정).

**stage C 자산**: vDriver repo HTAP 하니스(Zipfian skew 업데이트 + 60s long reader + chain-length CDF) = C단계 워크로드 템플릿(design-gc §10).

**다음**: Step 1a-ii 통합(GC `delete`→`retire` / search `Guard` / BG `reclaim`).

---

## 2026-06-18 — 세션 1 (이어서): 프로토타입 완성 (B단계) ✅ 단일스레드

**분석(멀티에이전트 워크플로)**: DIVA·One-shot GC 논문 정독 + vDriver 출처 조사(웹) + 우리 GC 코드 포렌식 → 라인 단위 수정 설계. (종합 에이전트의 "epoch 50 mutation 스킵" 제안은 검토 중 오류로 판명 → early-return 윈도잉 보존.)

**deadzone 출처 판정**: 공개 DIVA repo 없음. deadzone 계보는 **vDriver(SIGMOD'20 = "Long-lived Transactions Made Less Harmful")**. 우리 코드는 알고리즘 **재구현**(복사 아님) → 라이선스 의무 없음, 보고서 인용은 vDriver로 정정 권장.

**수정**:
- snapshot 보존: `trx_t` 복사 생성자 + `startWriteTrx`가 read-view 기록
- deadzone: 생성자 `oldest_low_limit_id` 저장 + 빈 snapshot 가드
- GC sweep 메모리안전: 순회 종료조건, prune double-advance/`prev_node`, epoch 양방향 unlink, empty 판정, window underflow 가드
- `garbage_collect` 완료 시 `true`(warm-up early-return은 보존)
- insert↔GC 리스트 방향 통일: dummy=head + head-insert + `epoch_node_wrapper.next` 초기화
- `search`가 최신 가시버전 반환(기존 oldest 반환 버그 수정)

**검증**: 신규 `correctness_test.cpp` 6개(MvccVisibility·GcDeadzone·GcEndToEnd) 전부 통과 + **ASAN(use-after-free/overflow) 클린**. 기존 단일스레드 GC 테스트(`create_1M_dummy_read_transaction`, `*_with_gc`)도 통과(이전엔 크래시 위험).

**미룬 것**: 멀티스레드 GC 동시성(reclamation), 빈 snapshot fast-path, dummy-list 누수, Kuku `LocFuncTests.Randomness`.

**다음**: C단계(HTAP/long-txn 워크로드 baseline 대비 측정) 또는 멀티스레드 GC 동시성 하드닝.

---

## 2026-06-18 — 세션 1 (이어서): 빌드 부활 (A단계) ✅

**환경 구축**: WSL2 Ubuntu 26.04(배포는 `--no-launch`로 등록 후 root 운용) + build-essential / gcc 15.2 / cmake 4.2 / git.

**빌드 블로커 수정**
- CMake 버전 문자열 `3.1Threads::Threads4` → `3.16`
- include 대소문자(`accelerateMvcc`→`accelerateMVCC`) — main.cpp, CMakeLists (리눅스 케이스 민감)
- kuku 링크: Windows `.lib` 하드코딩 → `add_subdirectory(Kuku)` + `Kuku::kuku`(소스 빌드, transitive include)
- `trxManager.h`에 `<algorithm>` 추가(`std::remove`; gcc15 빌드 실패 해소)

**결과**: `cmake --build` 성공 → `AccelerateMVCC`(데모), `test_with_google`(gtest) 생성. 데모 실행 OK. 안전 테스트(GC 제외) 31개 중 **30 통과**.
- 베이스라인 insert 벤치(1M): vector 7ms / interval-list 53–73ms (record 1·3·10), vector+lock 10ms.
- **알려진 이슈**: `LocFuncTests.Randomness`(Kuku 자체 테스트) 실패 — 동일 seed의 두 LocFunc 결과 불일치(gcc15/Kuku 재현성 추정). KukuTable query/populate/fill·우리 insert는 정상이라 기능 무영향. B에서 점검.

**빌드 레시피**(WSL): `cmake -S /mnt/c/Users/USER/projects/AccelerateMVCC -B ~/acc-build -DCMAKE_BUILD_TYPE=Release && cmake --build ~/acc-build -j`

**다음**: B단계 — GC/deadzone 버그 수정 + insert/search/GC 정확성 테스트.

---

## 2026-06-18 — 세션 1 (이어서): 오픈소스 독립 레포 전환

**한 일**
- fork였던 저장소를 **독립 standalone 레포로 전환**. GitHub는 자동 detach 미지원 → 기존 fork를 임시 이름으로 rename → 같은 이름으로 새 비-fork 레포 생성 → `master`·`feat/deadzone-detector` push.
- 오픈소스 정비: MIT LICENSE(하태성), 루트 README(badges·아키텍처·로드맵), 저장소 설명, topic 12개.
- `docs/`를 master에 병합(루트에서 바로 보이도록).
- 결과: `isFork=false`, default=master, MIT 인식, public.

**비고**
- **단독 프로젝트로 정리**: 기존 fork 저장소 삭제, LICENSE·README·docs에서 공동작업자 표기 제거(하태성 단독). 코드는 향후 전면 재작성 예정.
- 코드 이력 손실 없음(epochlist 실험은 master 히스토리에 merge→revert로 포함).

---

## 2026-06-18 — 세션 1: 재개 & 현황 파악

**한 일**
- 3년 전(마지막 2023-07) 중단된 저장소를 GitHub에서 가져와 4개 브랜치 분석.
- 코드 전체 정독 + Google Drive `AccelerateMVCC` 졸프 설계 문서(159KB) 분석 → 문제·아키텍처·중단 지점 파악.
- 빌드 환경 점검: 이 PC에 **WSL/MSVC/g++/cmake 모두 미설치**, 현재 셸 비관리자.
- 문서 토대 작성: `docs/README.md`, `docs/findings.md`, `docs/progress-log.md`.
- 프로젝트 메모리 기록.

**결정**
- 범위: 1차 **A+B+C**, 최종 **A+B+C+D**. 진행하며 문서/리포트 정리.
- 개발 환경: **WSL2(Ubuntu)** — C/D가 리눅스 전용이므로 처음부터 리눅스로.

**발견(빌드 블로커)**: CMake 버전 문자열 손상, kuku 경로 하드코딩, include 대소문자 불일치(리눅스 실패). → findings #1~#3.

**다음 할 일**
1. (사용자) 관리자 PowerShell에서 `wsl --install` → 재부팅 → Ubuntu 사용자 설정.
2. (Claude) WSL에서 `build-essential cmake git` 설치 → CMake/include/kuku 링크 정리(A) → 컴파일 & 기존 벤치 실행.
3. 이후 B(병합·버그수정·정확성 테스트)로 진행.
