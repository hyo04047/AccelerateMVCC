# 진행 로그

진행 상황을 세션별로 기록. 최신이 위.

---

## 2026-06-22 — 세션 7: D-4 ④ 읽기연결 4c·4d-prep·4d(authoritative serve) 완료 — 캐시 결과 실제 서빙·정확성 증명

> 세션 6에서 4c/4d-prep까지 진행(아래 세션 6 엔트리는 4b까지 기록). 이 세션: 재개검증(HEAD `f62c127` clean·origin 동기화, standalone 32 green Release/ASan/TSan, 통합 mysqld 4d-prep 게이트 통과) → serve-safety 적대적 audit → **4d authoritative serve 완성**.

**4c ✅ 캐싱 제외 게이트 (`8ec44bb`·`7dcccaa`·`48fe24b`)**: off-page LOB(`rec_offs_any_extern`)·virtual column(`n_v_cols>0`) 행은 populate 제외(img_len=0→consult MISS, 4c-1); instant-DDL은 consult-side 거친 게이트(reader 테이블 row-version>0이면 MISS, 4c-2 — per-entry 태그는 reader-era 값이라 틀린 신호로 진단됨). coverage(`build_cov.sh`, shadow): 표준 HTAP 깊은 읽기 hit≈100%(4G/256M BP, 8/32 writer, dropped=0). ⚠️LOB-heavy 한계는 최종검증 점검.

**4d-prep ✅ (`f62c127`)**: 캡처를 전체 물리 record+extra로 확장 → 캐시로부터 합성한 record가 vanilla `*old_vers`와 byte-동일(construct_ok=12998·construct_BAD=0) 임을 shadow 증명(서빙 X = 리스크 0).

**serve-safety 적대적 audit ✅ (워크플로 12에이전트, 5 mapper + 6 적대적 각도)**: 4d가 캐시-합성 rec를 서빙할 때 소비 경로가 version rec의 page-relative 헤더(heap_no/n_owned/next-ptr)를 읽는지 검증 — **safety_refuted 0/6**. 근거: vanilla도 standalone version을 만들 때 그 헤더 영역을 opaque 복사(실은 uninitialized heap 바이트)하므로 vanilla가 맞는 이상 그 필드는 비소비; InnoDB 자체 주석도 "old version은 page에 없다고 가정 못 함"을 명시. 유일한 page-context 후보(spatial debug 경로)는 가드로 unreachable. 판정 CONDITIONAL = 조건부 SAFE(조건: in_heap 복사·offsets 재파싱+make_valid·virtual col 제외·mismatch면 vanilla·MISS면 walk fallback).

**4d ✅ authoritative serve**: **4d-1**(consult를 walk 앞으로 hoist + 캐시 키를 live top rec에서 추출, 여전히 shadow) — construct_BAD=0·construct_ok==hit(12993)로 consult 위치 이동이 정확성-중립임 입증. **4d-2** serve 스위치(env `ACCEL_AUTHORITATIVE`, 기본 0=off=shadow): hook에 2단계 토글+serve counter(`accel_authoritative_mode`/`accel_note_serve`). mode 2(verify-serve = walk+byte-compare 후 캐시 서빙): **served = construct_ok = hit = 12988 · construct_BAD = 0** = 서빙한 답 전부 vanilla와 byte-동일; mode 1(serve-only = walk skip): served = hit = 12985, held-snapshot reader 13 SUM 일관 + **mode 2와 동일 SUM(679715)** = walk-skip 답이 검증 경로와 일치. virtual col 행 serve 제외·mismatch면 vanilla 유지·MISS면 walk fallback·양 모드 enq==drained·dropped=0·snapshot 불변. 재현 `build_d4d1.sh`·`build_d4d2.sh`, 설계·결과 [design-D4b-shadow.md](design-D4b-shadow.md) §13.

**불변식 유지**: 기본 OFF=shadow(평상 동작 불변), serve는 LOCATOR가 아니라 검증된 byte-동일 record, mismatch/MISS는 vanilla/walk fallback = 틀린 서빙 구조적 불가. lock-free·epoch·deadzone·disk-based HTAP 틀 유지.

**⑥ 성능 payoff ✅ (최종 증명, `build_d6.sh`)**: held-snapshot deep read latency를 vanilla walk(mode 0) vs serve-only(mode 1)로 buffer pool 3종에서 측정(churn으로 chain을 깊게 한 뒤 held snapshot이 purge를 막아 깊이 유지, deep scan latency는 MySQL profiling, undo page read는 `Innodb_buffer_pool_reads` 델타):

| BP | vanilla walk (mode 0) | serve-only (mode 1) | 개선 | deep-scan 물리 read |
|---|---|---|---|---|
| 4 GB | 0.80 s | 0.17 s | ~4.7× | 0 → 0 |
| 256 MB | 76.2 s | 0.16 s | ~490× | 796,259 → 0 |
| 64 MB | 123.4 s | 0.16 s | ~775× | 1,385,670 → 8 |

→ serve-only latency가 **BP 크기와 무관하게 ~0.16s로 평탄**(D-0의 "작아질수록 폭증" 절벽이 소멸). 메커니즘 직접 증거 = deep-scan 물리 read: vanilla는 작은 BP에서 evict된 undo page를 80만~140만 재읽기, serve-only는 0~8(undo walk skip → undo I/O 제거). 큰 BP는 version 재구성 CPU 절약(~4.7×), 작은 BP는 undo I/O 제거(~775×). correctness=모든 scan SUM 동일(679715, snapshot 불변)·served=2000·construct_BAD=0. **사용자 가설(작은 BP에서 HTAP read I/O 폭발) 데이터로 입증 + 캐시가 정확히 그 지점 해결 = D-4 목적(InnoDB HTAP/LLT 성능 향상) 달성, 1차(A+B+C)+최종(D) 목표 완료.** **다음 = ⑤ purge-view GC**(현재 GC off라 캐시 무한 성장 → InnoDB read-view 기준 메모리 회수로 "deadzone 제외 working-set" bound 완성, 1c-5 선행) / 최종검증(LOB·FTS·spatial·큰 테이블·mysqld ASan/TSan). **최종 산출물 = 논문(한글본 + 영문본).**

**⑤ purge-view GC 착수 — 설계 locked + 5-0 done**: 적대적 설계리뷰(워크플로 59에이전트, `GO_WITH_CONDITIONS`; 안전기둥 2개 유지 = over-reclaim은 perf-only[MISS→walk]·EBR가 serve UAF 차단) → cheap-collection 연구(계보 DIVA/vDriver/vWeaver + 일반 MVCC-GC + over-approximation 정리)로 **hot-mutex 회피 설계 확정**. 핵심: deadzone를 active read-view의 **conservative superset**으로 만들면 "중간-과회수 → 틀린 서빙"(리뷰가 잡은 유일 correctness 구멍)이 **구조적으로 배제**되고 잔여는 메모리 손해뿐 — **superset 정리**(뷰를 더하면 구멍이 잘게 쪼개질 뿐 넓어지지 않음, prunable(S)⊆prunable(A) for S⊇A; 위험은 오직 under-approximation). 수집 = **A**(InnoDB `purge_sys->view` 공짜 읽기=안전 바닥) **+ B**(InnoDB가 read-view open 때 **이미 쥔 trx_sys mutex에 편승**해 우리 leaf-domain lock-free registry로 view 미러, 닫기는 lazy) → 새 자물쇠 0으로 in-middle(LLT 이득) 회복 = vDriver SetSnapshot 패턴(우리 계보). C(검색에 회수 묻기)·D(거친 epoch-bucket)는 보조/fallback. **논문 기여 = "derived·authoritatively-served MVCC 캐시에 특화한 superset-안전 정리"**(vDriver/DIVA는 버전 저장소를 소유해 stale deadzone OK지만 우리는 InnoDB를 비추며 서빙 → over-prune이 틀린 서빙 → superset이 그걸 배제하며 hot-mutex 회피를 정당화). **5-0 done(이 커밋)**: ① deadzone 고정배열(50칸) 오버플로 clamp(실서버 active view >50이면 GC 스레드가 매 사이클 힙 손상 → loop를 NUM_DEADZONE에서 멈춤; 초과 구멍 drop = under-reclaim = safe) ② head-never-retired debug assert(head-prune 미사용·head-prepend가 plain store라 head 회수 시 two-writer race → 단일 retire 진입에서 superseded_ts==UINT64_MAX 금지 못박음). standalone 32 green Release/ASan/TSan(assert가 Debug서 실작동 = 불변식 모든 GC 경로서 확인). 설계·증분 5-0~5-3·must-fix·미해결질문 [design-D5-gc.md](design-D5-gc.md). **다음 = 5-1**(leaf-domain push hook[A+B]+deadzone-from-view, GC off, shadow로 superset·clock·interior-over-prune 음성대조 검증 + B publish 비용 측정). InnoDB 소스 수술 = multi-session.

---

## 2026-06-22 — 세션 6: D-4 ④ 읽기연결 4a+4b(SHADOW consult) 완료 — wrong-result 관문 통과(hit_MISMATCH=0)

> 핸드오프대로 맥락 복원 + 3게이트 검증(HEAD 189c172, 20→24 correctness green, build_d2img enq==drained) 후 **④ 읽기연결** 진행. "우리 in-memory cache가 디스크 MVCC를 consistent하게 반영하나"를 shadow byte 비교로 실측 입증.

**4a ✅ (`1a79b83`)**: InnoDB `ReadView::changes_visible` 4분기(up/low_limit·creator·m_ids)를 `include/read_view_mirror.h`에 정확 미러 + search의 ad-hoc max-trx_id predicate 교체. 오프라인 단위테스트 `ReadViewMirror.*`. 읽기전용 reader에선 기존과 동치라 20 correctness 불변(24 green).

**4b ✅ SHADOW consult (`dcbd81f`·`0ba4781`·`4cda4f5`·`3f4ac95`·`5540ba7`·`ed3f757`)**: 적대적 설계 리뷰(워크플로 wf_16b038a8, verify 단계 hang→journal에서 6 find/84 verdict 직접 종합)로 must-fix 6개 도출 후 하위증분 구현. **4b-0** 노드 키 version_trx_id(=old DB_TRX_ID)/writer_trx_id 분리(consume 버그 교정). **4b-1** full-PK 식별 바이트+delete-mark + 캡처 윈도우 `rec_offs_data_size`(M1). **4b-2** per-key contiguity bookkeeping(per-key arrival은 row X-lock+FIFO ring으로 version 순서 → gap의 유일 원천=ring drop, linkage로 검출). **4b-3a** `Accelerate_mvcc::consult()`(full-PK+changes_visible+contiguity, EBR Guard가 image 복사까지 span=M2)+오프라인 6 테스트. **4b-3b** `row0vers.cc`에 SHADOW 배선+byte 비교 — **calls=13000 hit_match=12998 hit_MISMATCH=0 noncontig=2**. **4b-3c** 매트릭스(60s LLT 29998/30000·rollback 0오답·충돌·동시성 ASan/TSan)+오프라인 negative control. standalone 32 green.

**불변식**: consult=LOCATOR/HINT — 모든 결과 HIT(=vanilla byte) 또는 MISS(full walk), silent wrong result 구조적 불가. shadow=동작 불변. 설계·결과 [design-D4b-shadow.md](design-D4b-shadow.md). 재현 `build_test_4b3.sh`·`build_d4b3b.sh`·`build_d4b3c.sh`. **다음 = 4c**(캐싱 제외 게이트) → 4d authoritative → ⑤ purge-view GC → ⑥ D-0 곡선 평탄화 측정.

---

## 2026-06-21 — 세션 5: D-1b 재검증 + D-2/D-3 적대적 리뷰 + D-0 비용 분해 → 방향=version 캐시 확정

> 새 세션 재개. 핸드오프대로 맥락 복원 → 검증 → D-2 설계 진입. **방향 전환**: consult-as-locator(roll_ptr 점프)로는 D-0 평탄화가 안 됨을 적대적 리뷰+측정으로 확정 → **version-level materialized cache**로 재정의.

**재개 검증 ✅**: HEAD=`997d5c0`(clean, origin 동기화) → 20 correctness Release/ASan/TSan green 재확인 + `integration/scripts/build_d1b4.sh`로 통합 mysqld 무결(enq==drained, dropped=0, cur_key_chain_len 1442→19988, clean shutdown). populate 경로(D-1b) 재현 확인.

**D-2/D-3 적대적 설계 리뷰 ✅ (워크플로 42에이전트, 6렌즈 병렬→finding별 verify→synth; go_with_conditions, 23/35 confirmed)**: 스코프 (b)(consult+purge-view GC). **load-bearing 결론**: undo는 delta라 version을 top→down 순차 재구성(`trx_undo_prev_version_build`→`row_upd_rec_in_place`) → **consult-as-locator는 undo apply 횟수를 못 줄여 D-0 평탄화 불가**. D-3가 우리 인덱스를 compact해도 InnoDB 물리 undo chain은 그대로(Stage C 5500×는 우리 in-memory list 비용이라 전이 X). 유일한 정직한 길 = per-snapshot materialized-version cache. correctness blocker 5건(populate가 writer trx_id 저장·search≠changes_visible·GC가 standalone Trx_manager 기반·rollback/drainer-lag/recycled roll_ptr·head 2-writer race)에 대해 안전 consult 형태(LOCATOR + purge-view gate + head watermark + real-chain 재앵커, miss→full walk) 도출. 상세 [design-D.md](design-D.md) §11, 종합본 `/mnt/c/.../d2_review_synth.txt`.

**D-0 비용 분해 측정 ✅**: ① BP 4G — deep scan 0.49s, **물리 disk read 4(≈0)**·논리 page 접근 672만 = **CPU-bound**(buffer-pool-resident인데도 느림). ② gdb sampling **40/40**이 `row_search_mvcc`→version build(원래 주원인 확정). ③ **BP sweep** — 4G 0.49s/read 4 → 64M **75s/read 6만(~150×)** → 16M 70s/read 5.7만 = 작은 BP에서 **I/O-bound 전환** + churn tps 18.9k→14.9k(pollution). → 사용자 가설("메모리/buffer pool 작을 때 HTAP I/O 문제 폭발") 데이터로 입증. 스크립트 레포 밖 `d0_profile1.sh`·`d0_profile2.sh`·`d0_bpsweep.sh`.

**방향 결정**: D = consult-as-locator가 아니라 **version-level materialized cache**(재구성 version image를 in-memory, deadzone 제외 working-set, ephemeral=durability/atomicity InnoDB·crash 시 재구축, miss→full walk). 큰 BP=재구성 CPU·작은 BP=undo disk I/O+pollution 제거, 다양한 메모리 환경(특히 작은 BP)에서 효과(DIVA류 정합). buffer pool과 차별=page 캐싱(재구성 매번) vs 재구성 결과 캐싱(0회), 같은 메모리로 더 효율. ACID는 캐시가 authority 아님(committed past version immutable, isolation=changes_visible 재현+InnoDB 검증)으로 보존. **개정 증분**: D-2a populate fix→2b changes_visible 미러→2c consult shadow(mismatch=0)→2d authoritative→D-3 purge-view GC(1c-5 선행)→D-4 cache. **다음 = D-4 설계 전 ACID/correctness 적대적 검증.** 상세 [design-D.md](design-D.md) §12.

---

## 2026-06-21 — 세션 4 (이어서): Stage D 착수 — D-0(InnoDB baseline) ✅

> Stage C lock-in(커밋·push) 후 사용자 요청으로 **A~C 논문급 보고서**(`docs/REPORT.md`) 작성·커밋, 이어서 **Stage D(InnoDB 실통합)** 착수. 설계는 [design-D.md](design-D.md).

**D 설계**: hook 3지점(populate=undo create, consult=consistent read, deadzone↔trx_sys 동기화). MySQL 소스에서 hook 함수 위치 확인 — consult=`row0vers.cc:1249 row_vers_build_for_consistent_read`, populate=`trx0rec.cc:2117 trx_undo_report_row_operation`. 결정: **MySQL 8.4.10 LTS + scoped PoC + gcc-13**(gcc15 빌드 리스크 회피).

**D-0 ✅ (vanilla baseline)**: MySQL 8.4.10 RelWithDebInfo를 gcc-13/ninja로 빌드(11분, 에러 0) → mysqld 기동 + sysbench 1.0.20. **발견**: OLTP throughput은 LLT에 거의 불변(1,867→1,882 tps, 30s/in-memory)이나 **history list length 360→56,752 폭증**(purge가 LLT에 막힘 재현). **진짜 비용은 analytic read** — held snapshot 하 `SELECT SUM(LENGTH(c))`(1000행 scan)을 OLTP churn 중 측정하니 latency **0.7ms→1,355ms (~1,900×)** 증가(history list 2.07M). **baseline metric 확정 = held-snapshot analytic read latency vs churn**(consult hook D-2이 평탄화할 대상). throughput-only는 단시간/in-memory엔 신호 안 남. 상세·재현 [design-D.md](design-D.md) §7.

**D-1a ✅ (populate hook 배선)**: 통합 facade `integration/innodb/accel_hook.{h,cc}`(InnoDB와 디커플된 plain 함수) + `build_d1a.sh`가 MySQL 트리에 복사+멱등 패치(CMakeLists source 추가, `trx0rec.cc` include + 성공 경로 hook call @2325). D-1a는 **count-only**(atomic+stderr, hot path 무위험)로 배선만 증명. 결과: mysqld 재빌드 OK, churn 1.91M txn @ 31,880 tps(vanilla와 동일=오버헤드 무시), **HOOK EVIDENCE** `[accel] undo records seen: 200000…1800000`(실제 table=1064·monotonic trx_id·undo loc·op=MODIFY) → InnoDB→accelerator 배선+빌드통합 end-to-end 검증. 상세 [design-D.md](design-D.md) §8.

**D-1b 적대적 설계 리뷰 ✅ (워크플로 6에이전트: 5렌즈→종합)**: naive D-1b(hook에서 `insert()` 직접)는 mysqld 깨짐 — blocker 5건(PK 미전달·Kuku thread-unsafe·page latch 하 malloc·cuckoo 무한/silent-drop·GC가 SIM Trx_manager 기반). **안전 설계 = "enqueue-under-latch, insert-off-latch, GC off, consult hint+fallback"**: hook은 noexcept로 lock-free ring에 스칼라만(+pk_hash+old_db_trx_id), 단일 drainer가 off-latch single-consumer insert. D-1b를 4증분으로 분할(D-1b-1 키배선 count-only → 2 ring/drainer 스캐폴드 → 3 진짜 insert·GC off → 4 하드닝). 상세 [design-D.md](design-D.md) §9.

**D-1b-1 ✅ (키 배선)**: hook을 pk_hash+old_trx_id로 확장, call site(trx0rec.cc 성공 경로)에서 clustered PK를 FNV-1a 해시(`rec_get_nth_field(index,rec,offsets,..)` — 8.4는 index 첫 인자) + prior DB_TRX_ID(`row_get_rec_trx_id`) 추출, MODIFY-op만 필터. body는 count-only(데이터 구조 미변경). 검증: pk_buckets_seen=676/1024(row-unique 키), 같은 행 반복→동일 해시(결정적), old<trx, op=2만, 32.3k tps(=vanilla). 패치는 repo `integration/innodb/d1b1_patch.pl`(멱등), 스크립트 `build_d1b1.sh`.

**D-1b-2a ✅ (lock-free ring 격리 검증)**: bounded MPMC ring(Vyukov per-slot seq, `integration/innodb/accel_ring.h`) header-only 구현 + standalone 스트레스 테스트(`accel_ring_test.cpp`, 8 producer+1 consumer, torn-read 검출기 내장, 작은 ring으로 drop 경로 강제). Release/ASan/TSan **전부 PASS**: enq==deq(모든 enqueue dequeue됨), enq+dropped==2.4M(회계 일치), torn=0, TSan data race 0. EBR/marked-pointer처럼 격리-후-통합.

**D-1b-2b ✅ (ring+drainer를 mysqld에 배선)**: accel_hook이 hook에서 ring enqueue(noexcept, full→drop), off-latch drainer 스레드가 pop+count(진짜 insert는 D-1b-3). InnoDB 생명주기: `srv0start.cc` srv_start 끝에 `accel_init()`(drainer 시작, latch 밖)·srv_shutdown 시작에 `accel_shutdown()`(stop+join) + ready gate. 검증(8 동시 producer churn 1.8M txn @ 29.9k tps): `[accel] init` 로그, drained≈enq·dropped=0(drainer가 따라잡음, 65536 ring), pk_buckets=676/1024(row-unique 키 ring 통과), shutdown에 **enq==drained=1,796,527 정확 일치 + clean join**. ring thread-safety는 D-1b-2a TSan, 통합/생명주기는 여기서.

**D-1b-3a ✅ (빌드통합)**: Accelerate_mvcc + epoch_table + interval_list + trxManager + **Kuku(kuku.cpp + blake2b.c + blake2xb.c)**를 innobase `INNOBASE_SOURCES`에 추가(절대경로) + include 경로(우리 include/·Kuku/src·생성된 config.h의 `~/acc-build/Kuku/src`) + 우리 소스 `-w`(MySQL -Werror 회피). accel_hook이 `accelerateMVCC.h` include + 전역 `Accelerate_mvcc(0)` 생성(BG GC off). 빌드 rc=0(첫 시도는 blake2xb undefined reference로 .c 누락 발견→추가), mysqld 기동 `[accel] accelerator constructed`, churn 944k @ 31.5k tps, clean shutdown. consume는 아직 count-only. **우리 코드가 MySQL 빌드 그래프에 실제 진입.** 재현 `build_d1b3a.sh`, 방법 [design-D.md](design-D.md) §10.

**D-1b-3b ✅ (진짜 insert)**: drainer consume()가 기존 저수준 `insert(table_id,pk_hash,trx_id,space,page,offset)` 호출(단일 consumer라 g_accel 단일 mutator=무경쟁, Trx_manager/get_mutex 미사용). ctor에 `kuku_log2` param(기본 10=테스트 무영향, integration=16=64k bin으로 silent cuckoo 실패 회피), **GC off**. 검증: 20 correctness Release green, mysqld churn 1.34M @ 33k tps, drained==enq=1,338,217·dropped=0·clean shutdown, **cur_key_chain_len=2616**(hot key chain 실제 적재·성장; GC off라 자람=예상). live_epoch_buckets=0은 GC 부기라 정상. **→ populate 경로(D-1b) 기능 완성**: AccelerateMVCC 인덱스가 mysqld 안에서 실제 InnoDB undo로 채워짐(latch 하 enqueue→off-latch single-consumer insert).

**D-1b-4 ✅ (하드닝)**: hook 안전 불변식을 컴파일 타임으로 못박음 — `accel_ring.h`에 `static_assert(is_trivially_copyable<UndoRec>)` + `sizeof(UndoRec)==8*u64`(latch 하 enqueue가 alloc-free trivial copy임을 보장 + 슬롯 bloat tripwire) + accel_on_undo에 noexcept/no-alloc/no-lock/no-InnoDB-call(leaf domain) 불변식 명문화. 검증: mysqld build rc=0(static_assert 통과)·boot·churn 672k @ 33.6k tps·drained==enq·clean shutdown. **→ D-1b(populate 경로) 전체(D-1a~1b-4) 완성.**

**→ 다음 = D-2(consult, 최종 payoff·큰 새 단계)**: `row0vers.cc:1249 row_vers_build_for_consistent_read`에서 accelerator로 가시 version 점프, InnoDB `ReadView`(m_low/up_limit_id, m_ids) 3-way `changes_visible`를 노드 DB_TRX_ID로 재구현(우리 max-trx_id 루프 X), accelerator=LOCATOR(roll_ptr→InnoDB 검증), **miss는 일반 chain walk fallback 필수**. D-0 baseline(analytic 0.7ms→1.35s) 평탄화 측정이 payoff. consult 전 deadzone GC를 InnoDB purge view로 재구동(D-3)·rollback/purge 정합 필요(design-D §9 deferred). wrong-result 리스크라 적대적-리뷰급 설계 권장 — 신선한 세션에서.

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
