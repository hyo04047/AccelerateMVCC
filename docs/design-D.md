# 설계 문서 — Stage D (MySQL/InnoDB 실통합)

> 최종 목표: standalone에서 입증한 가속 인덱스 + deadzone GC를 **실제 InnoDB**에 연결하고, sysbench HTAP로 **vanilla MySQL 대비** 효과를 측정. (1차 목표 A+B+C는 [REPORT.md](REPORT.md)에 정리.)
> 작성: 2026-06-20 (세션 4, Stage C 완료 직후 착수)

---

## 0. 목표 & 성공 기준 (DoD)
- 가속 인덱스를 InnoDB의 **consistent-read 경로**에 연결해, version chain을 끝까지 걷지 않고 **가시 version의 undo 위치로 바로 점프**.
- accelerator의 deadzone GC가 InnoDB의 active read view(global-min)와 동기화돼 compact 유지.
- **DoD**: sysbench HTAP(OLTP update + 60s LLT)에서 vanilla MySQL 대비 ① LLT 하 read latency/throughput 개선, ② version 탐색 비용(undo page 접근/CPU) 감소를 수치로 제시. **correctness는 전제** — 통합본의 가시성이 vanilla와 동일(MVCC 정합).

---

## 1. InnoDB MVCC read 경로 (hook 대상 파악)
InnoDB consistent read의 핵심 흐름(개략):
- `row_search_mvcc()` — 인덱스에서 record를 찾고, 현재 record가 read view에 안 보이면 옛 version을 만든다.
- `row_vers_build_for_consistent_read()` — record의 `DB_ROLL_PTR`로 undo log를 따라가며 **version chain을 한 칸씩** 거슬러 read view에 보이는 version을 만들 때까지 반복. **여기가 긴 chain에서 비싼 지점**(undo page를 buffer pool로 read + latch).
- `ReadView`(구 `read_view_t`) — `m_low_limit_id`/`m_up_limit_id`/`m_ids`(활성 trx id). `trx_sys->mvcc`가 view를 발급/관리.
- `purge_sys` — 가장 오래된 view 아래의 undo를 회수(= tail-only). LLT가 view를 잡으면 purge가 막힘.

**hook 3 지점**:
1. **populate(쓰기)**: update/delete가 옛 version의 undo record를 만들 때(`trx_undo_report_row_operation` 부근), 그 (space, page, offset, trx_id, table_id, PK) 메타데이터를 accelerator에 insert.
2. **consult(읽기)**: `row_vers_build_*`가 chain을 걷기 전에 accelerator에 (record, read view)로 질의해 **가시 version의 undo 위치를 직접** 얻고, chain walk를 건너뜀(또는 단축).
3. **GC 동기화**: accelerator deadzone를 `trx_sys`의 active view 집합으로 구성(우리 `generate_dead_zone`의 입력 = InnoDB active read view들). purge가 못 줄이는 in-middle을 accelerator가 회수.

## 2. 프로토타입 ↔ InnoDB 매핑
| 프로토타입 | InnoDB |
|---|---|
| `(table_id, index)` 키 | table_id + clustered PK |
| `undo_entry`(space/page/offset) | undo record 위치(DB_ROLL_PTR 디코드) |
| `trx_id` | InnoDB trx_id |
| active_trx_ids / read view | `ReadView::m_ids` / trx_sys MVCC |
| deadzone(active 사이 hole) | active read view 집합으로 동일 구성 |
| EBR Guard(traversal) | read 1회 수명(MTR/page latch와 별개의 reclaim grace) |
| BG GC 액터 | purge thread와 병존(또는 별도 background) |

설계상 accelerator는 **ephemeral**(crash 시 InnoDB undo가 source of truth) → logging/recovery 불필요.

## 3. 빌드/환경 계획
- **타깃 버전**: MySQL **8.4 LTS** 권장(안정·문서화·InnoDB 구조 최신). (대안 8.0.) — **사용자 확인 필요(§6).**
- **빌드**: WSL native(`~`, 953G 여유)에서. deps `apt install -y bison libssl-dev libncurses-dev pkg-config libtirpc-dev zlib1g-dev`(+ boost는 `-DDOWNLOAD_BOOST=1 -DWITH_BOOST=~/boost`). `cmake -DWITH_DEBUG`(개발) / RelWithDebInfo(측정).
- ⚠️ **gcc 15 리스크**: MySQL 8.x는 gcc 15 공식 지원 밖 → `-Werror` 충돌/std 변경 가능. 1순위 시도 후 실패 시 **gcc-12/13 설치해 그걸로 빌드**(`-DCMAKE_C_COMPILER`/`CXX`). 이게 D-0의 첫 관문.
- **sysbench**: `apt install sysbench` 또는 소스. HTAP 워크로드 = `oltp_update_non_index`(Zipfian) + 60s LLT 클라이언트.

## 4. 증분 (각 독립 검증 + 체크포인트)
| # | 목표 | 검증 |
|---|---|---|
| **D-0 ✅** | vanilla MySQL 8.4.10 소스 빌드(gcc-13, 11분) + 기동 + sysbench **baseline** 측정 | 완료 — §7 결과 |
| **D-1a ✅** | populate hook **배선**(count-only facade `accel_hook`) — InnoDB→accelerator 호출 경로 + 빌드 통합 증명 | 완료 — §8 |
| **D-1b-1 ✅** | 키 배선: hook에 **pk_hash + old_trx_id** 추가(call site에서 clustered PK FNV-1a 추출, `rec_get_nth_field(index,rec,offsets,..)`·`row_get_rec_trx_id`), MODIFY-op 필터, count-only | 완료 — pk_buckets_seen=676/1024(row-unique), 반복행 동일 해시, old<trx, op=2만, 32.3k tps(=vanilla) |
| **D-1b-2a ✅** | bounded **lock-free MPMC ring**(Vyukov, `integration/innodb/accel_ring.h`) + standalone 스트레스 테스트 | 완료 — Release/ASan/TSan PASS(enq==deq, torn=0, data race 0, drop 경로 발동) |
| **D-1b-2b ✅** | ring을 accel_hook에 배선(hook=enqueue) + off-latch drainer(pop+count) + InnoDB 생명주기(srv_start→`accel_init`, srv_shutdown→`accel_shutdown`) + ready gate | 완료 — drainer 동작, enq==drained(1.8M), dropped=0, clean shutdown, 29.9k tps |
| **D-1b-3a ✅** | accelerator(4 .cpp)+Kuku(kuku.cpp+blake2b/xb.c)를 **innobase 빌드에 컴파일·링크**, accel_hook이 전역 `Accelerate_mvcc(0)` 생성(BG GC off), consume count-only | 완료 — build/link/boot OK, 31.5k tps, clean shutdown(§10) |
| **D-1b-3b ✅** | drainer consume()가 진짜 저수준 `insert()`(단일 consumer=g_accel 단일 mutator) + ctor `kuku_log2` param(integration=16) + GC off | 완료 — 20 correctness green, **cur_key_chain_len=2616**(인덱스 적재 확인), insert==drained=1.34M, 33k tps |
| **D-1b-4 ✅** | 하드닝: hook noexcept 확인 + UndoRec **trivially-copyable·size 고정 static_assert**(latch 하 enqueue=alloc-free 보장) + leaf-domain/no-throw 불변식 명문화 | 완료 — static_assert 컴파일 통과, mysqld boot·33.6k tps·clean shutdown |
| **D-2** | **consult hook**(consistent read가 accelerator로 가시 version 위치 점프) | **가시성 vanilla와 동일**(정합성 필수) + chain walk 감소 |
| **D-3** | deadzone ↔ `trx_sys` active view 동기화 + BG GC가 in-middle 회수(purge 보완) | LLT 하 chain/undo 점유 감소, purge와 무충돌 |
| **D-4** | sysbench HTAP **vs vanilla** 측정 | read latency/throughput 개선 + version 탐색 비용 감소(perf) |

## 5. 리스크 (선제 식별)
- **gcc 15 ↔ MySQL 빌드 비호환**(D-0 관문) → older gcc fallback.
- **InnoDB 내부 API 침습성**: hook이 hot path라 잘못하면 오버헤드가 이득을 잡아먹음 → populate는 가볍게, consult는 chain이 길 때만.
- **정합성**: accelerator가 돌려준 version이 InnoDB read view 가시성과 **정확히 일치**해야(틀리면 wrong result) → D-2에서 vanilla 대조가 gate.
- **동시성**: InnoDB latch/MTR와 accelerator의 EBR/lock-free 모델 공존 — reclaim grace를 InnoDB read 수명과 맞춤.
- **규모**: D 전체는 multi-session. PoC(특정 read 경로 1개에 hook + 측정)로 가치 입증 후 확장 권장.

## 6. 착수 전 확인 (사용자)
- **MySQL 버전**: 8.4 LTS(권장) vs 8.0 vs 기타.
- **D 스코프**: 우선 **scoped PoC**(consult hook 1경로 + sysbench 측정으로 효과 입증) vs 처음부터 풀 통합 지향.
- **gcc**: 15로 우선 시도 후 안 되면 older gcc 설치 OK인지.
- (이후 D-0부터 작게 + 체크포인트로.)
- **확정(2026-06-21)**: MySQL **8.4.10 LTS**, **scoped PoC 먼저**, gcc는 **gcc-13** 사용(15 리스크 회피).

---

## 7. D-0 결과 (vanilla baseline, 2026-06-21)
환경: WSL2(16코어/30G), MySQL 8.4.10 RelWithDebInfo(gcc-13, ninja, 빌드 11분), sysbench 1.0.20, buffer pool 4G, `innodb-purge-threads=4`.

- **빌드/기동**: gcc-13으로 클린 빌드, mysqld 8.4.10 기동·sysbench 연결 OK. (root 운용 → `--user=root`; source build → `--lc-messages-dir=$BASE/share`.)
- **OLTP throughput는 LLT에 거의 불변**(1,867 vs 1,882 tps, 30s/buffer-pool-resident): 짧은 OLTP txn은 최신 read view라 깊은 체인을 안 걷고, 작은 테이블이 메모리에 상주해 undo I/O가 없음. **단 history list length는 360→56,752로 폭증**(purge가 LLT에 막힘 = 우리가 공격하는 메커니즘 재현).
- **진짜 비용 = analytic read(LLT 자신의 read)**: held snapshot 하에서 `SELECT SUM(LENGTH(c)) FROM sbtest1`(1000행 clustered scan)을 OLTP churn(oltp_update_non_index, pareto, 8thr) 중 6초 간격으로 측정 → latency가 **0.7 ms(scan0) → 1,355 ms(scan10, ~60s 후) = ~1,900×** 증가. history list 2.07M, OLTP 2.18M txn(29k/s). = LLT가 잡은 snapshot으로 version chain을 점점 깊이 되돌리는 비용(vDriver HTAP 비용의 MySQL 재현).
- **결론(baseline metric 확정)**: D의 비교 지표 = **held-snapshot analytic read latency vs churn 시간**(+ history list length). D-2 consult hook이 이 곡선을 평탄화하는 것이 목표(standalone에서 chain max 155로 잡았던 것의 InnoDB 판). throughput-only는 in-memory/단시간엔 신호가 안 남.
- 재현 스크립트(레포 밖): `build_d0a.sh`(deps+clone) / `build_d0b.sh`(빌드) / `build_d0d.sh`(baseline). MySQL 소스 `~/mysql-server`, 빌드 `~/mysql-build`.

## 10. innobase 빌드통합 (D-1b-3a, 재현)
accelerator를 mysqld에 넣는 방법(스크립트 `build_d1b3a.sh`가 멱등 적용):
- **소스**: `storage/innobase/CMakeLists.txt`의 `INNOBASE_SOURCES`에 절대경로로 추가 — `include/{accelerateMVCC,interval_list,epoch_table,trxManager}.cpp` + `Kuku/src/kuku/kuku.cpp` + **`Kuku/src/kuku/internal/blake2b.c`·`blake2xb.c`**(blake2xb undefined reference로 발견). 우리 소스는 innobase 정적 플러그인(libinnobase.a)에 함께 컴파일→mysqld에 자동 링크.
- **include**: 파일 끝에 `target_include_directories(innobase PRIVATE <repo>/include <repo>/Kuku/src ~/acc-build/Kuku/src)` — 마지막은 **생성된 `kuku/internal/config.h`**(Kuku cmake 산출, 우리 acc-build에 있음).
- **경고**: 우리 소스 + accel_hook.cc + blake2 .c에 `set_source_files_properties(... COMPILE_OPTIONS "-w")` — MySQL의 `-Werror`(format-security 등)와 우리 코드 경고 충돌 회피(우리 코드는 별도로 검증됨).
- accel은 leaf domain: accel_hook.cc만 `accelerateMVCC.h` include(InnoDB 헤더 X), 나머지 우리 .cpp는 InnoDB와 독립 TU라 매크로 충돌 없음. 네임스페이스 `mvcc`/`kuku`로 InnoDB 심볼과 무충돌.

## 8. D-1a 결과 (populate hook 배선, 2026-06-21)
통합 코드는 repo `integration/innodb/accel_hook.{h,cc}`(canonical), 스크립트 `build_d1a.sh`가 MySQL 트리에 복사+멱등 패치(CMakeLists에 source 추가, `trx0rec.cc`에 include + 성공 경로 hook call).
- **hook 지점**: `trx_undo_report_row_operation`의 성공 경로, `*roll_ptr = trx_undo_build_roll_ptr(...)` 직후 `return DB_SUCCESS` 직전(trx0rec.cc:2325). 전달값 = `index->table->id, trx->id, undo_ptr->rseg->space_id, page_no, offset, op_type`(= 우리 accelerator가 저장할 (table, pk-자리, trx_id, space/page/offset)).
- **D-1a facade = count-only**(atomic + 200k마다 stderr): hot path 무위험 검증용. 결과: mysqld 재빌드 OK, churn 1.91M txn @ **31,880 tps**(vanilla와 동일 = 오버헤드 무시 가능), mysqld 안정. **HOOK EVIDENCE**: `[accel] undo records seen: 200000…1800000`, 실제 table=1064·monotonic trx_id·undo loc(space 0xFFFFFFEF:page:offset)·op=2(MODIFY)로 ~1.8M회 발화. → **InnoDB→accelerator 배선 + 빌드 통합 end-to-end 검증.**
- **다음 = D-1b 리스크**(hot-path real insert): undo 생성은 `trx->undo_mutex` 등 InnoDB latch 보유 구간 직후 → 거기서 우리 accelerator의 alloc/lock/BG-GC를 호출하면 **latch-order/deadlock·alloc-in-critical-section·perf** 위험. D-1b 전에 adversarial 설계 리뷰로 안전한 호출 형태(예: 가벼운 enqueue 후 비동기 적재, BG-GC off, lock-free path) 확정 필요.

## 9. D-1b 적대적 설계 리뷰 (2026-06-21, 워크플로 6에이전트: 5렌즈 병렬→종합)
naive D-1b(hook에서 `insert()` 직접 호출)는 mysqld 깨짐 — blocker 5건:
1. **PK 미전달**: accelerator는 `make_item(table_id,index)`로 키잉하는데 hook에 PK가 없어 모든 행이 한 chain에 붕괴 → consult 불가.
2. **Kuku thread-unsafe**(검증: `Kuku/src/kuku/kuku.cpp`에 lock/atomic 0): 다른 페이지 동시 쓰기가 한 전역 cuckoo table을 race → torn read/heap corruption.
3. **page latch 보유 중 malloc**(undo_entry/epoch_node/wrapper): arena-lock↔page-latch 교차 사이클 + latch hold 증폭.
4. **cuckoo insert 무한/silent-drop**: 1<<10·max_probe=100, 신규 (table,pk)가 common path라 latch 하 eviction 폭증 + stash full 시 version 조용히 누락.
5. **GC가 SIM Trx_manager 기반**: 저수준 insert는 Trx_manager를 안 먹여 deadzone가 엉터리 → InnoDB reader가 필요한 version prune. **D-1b는 GC off 필수.**

**안전 설계 = "enqueue-under-latch, insert-off-latch, GC off, consult-validated-later"**:
- **hook(latch 하)**: `noexcept`, MODIFY 필터 → bounded **lock-free MPMC ring**에 스칼라만(table_id, pk_hash, trx_id, **old_db_trx_id**, space/page/offset, delete_mark) fetch_add+store+release publish. alloc/kuku/mutex/EBR/throw 0. ring full이면 **drop counter++ 후 return**(절대 block X).
- **drainer(off-latch, single consumer)**: ring을 pop해 진짜 insert(kuku query/insert + node alloc + epoch_table->insert)를 **단일 스레드로** → kuku/리스트 단일 mutator(기존 reclaimer/sweep 전제와 합치). drain lag 수 ms는 OK(consult는 hint+fallback).
- **키/값**: key=(table_id, **pk_hash**)(PK 필드 해시; MODIFY-op는 `rec`로 추출 가능). 노드에 **old DB_TRX_ID**(undo가 복원하는 version의 begin-ts = 가시성 trx_id; writer trx->id만 저장하면 boundary off-by-one) + delete-mark 1bit 저장.
- **accelerator 변경**(D-1b-3): Trx_manager/get_mutex 미사용 저수준 insert, ctor 사전생성 제거(키 동적 생성), kuku 크기 ≥1<<16, insert false=진짜 실패로 계약 수정, **GC off**(메모리 무한증가 = 이 단계 의도), 명시적 init/shutdown(static dtor 금지) + ready gate, accel=leaf-domain 불변식.
- **D-2로 미룸**: visibility는 InnoDB `ReadView`(m_low/up_limit_id, m_ids) 3-way `changes_visible`를 노드 DB_TRX_ID로 재구현(우리 search의 max-trx_id 루프 X). consult는 LOCATOR(roll_ptr 반환→InnoDB가 검증), **miss는 반드시 일반 chain walk fallback**(절대 'version 없음'으로 해석 X). purge invalidation·rollback 정합·GC를 InnoDB purge view로 재구동은 D-3.

## 11. D-2/D-3 적대적 설계 리뷰 결과 (2026-06-21 세션 5, 워크플로 42에이전트: 6렌즈 병렬→finding별 독립 verify→종합)
스코프 (b)(D-2 consult + D-3 purge-view GC 묶음)로 리뷰. **go_with_conditions, 35 findings 중 23 confirmed.**
- **🔴 consult-as-locator로는 D-0 곡선 평탄화 불가**(load-bearing): undo는 delta라 version을 top→down 순차 재구성(`trx_undo_prev_version_build`가 윗 version 받아 `row_upd_rec_in_place`로 한 칸 되돌림) — 가시 version의 roll_ptr만 줘도 InnoDB는 *언제 멈추나*만 바뀌지 *몇 번 apply하나*는 그대로. D-3가 우리 인덱스를 compact해도 InnoDB **물리** undo chain은 그대로 길다. Stage C의 5,500×는 우리 in-memory list(포인터 hop)를 걷는 비용이라 InnoDB delta-walk엔 전이 안 됨. LLT 중 InnoDB chain splice는 정직하게 불가(공유 roll_ptr·newer reader visibility·purge는 LLT가 막음). → **유일한 정직한 길 = per-snapshot materialized-version cache**(§12 방향 결정).
- **correctness blocker(전부 닫히는 안전 설계 도출)**: ① populate가 writer trx_id 저장(visibility key는 old DB_TRX_ID여야 — `accel_hook.cc:52`가 `r.old_trx_id`를 버림) ② search의 max-trx_id 루프는 `changes_visible` 아님(m_ids binary-search·id==creator 분기 누락) ③ GC가 standalone Trx_manager 기반(mysqld에선 빈값) → purge와 desync ④ rollback(commit 전 populate)·drainer-lag(stale-but-visible 반환)·purge되고 recycle된 roll_ptr ⑤ D-3 GC ON 시 head 2-writer race(drainer insert‖GC head-prune, plain store).
- **안전 consult 형태**: LOCATOR가 (writer_trx_id, version_trx_id=old DB_TRX_ID, roll_ptr, undo_no, delete_mark, full PK) 후보 반환 → ① writer가 purge-visible(`purge_sys->view.changes_visible(writer)`)이면 MISS ② live top record DB_TRX_ID > per-key head watermark면 강제 MISS(drainer-lag/ring-drop 방어) ③ InnoDB가 synthetic anchor(DB_TRX_ID=writer, DB_ROLL_PTR=candidate)로 **real chain에 재앵커** → 자기 per-fetch purge gate + 자기 `ReadView::changes_visible`로 최종 판정. **raw `trx_undo_get_undo_rec_low` jump 금지. consult false=무조건 full walk(절대 'no version' 아님).** → wrong-result door 전부 닫힘, 최악은 shortcut 놓침(perf).
- D-3 GC: deadzone를 standalone Trx_manager가 아니라 **InnoDB `trx_sys->mvcc` active read-view set(trx_sys_mutex 하 완전 열거)**로 구성, `purge_sys->view.low_limit_no`를 eviction boundary로(undo page recycle 전에 우리 노드 evict). 우리 in-memory 노드만 회수, InnoDB undo는 안 건드림. BG GC 켜기 전 1c-5(head prepend marked-ptr CAS)+epoch scalar atomic+EBR pool 사이징 선행.
- 종합본 전문: 레포 밖 `/mnt/c/Users/USER/d2_review_synth.txt`.

## 12. D-0 비용 분해 측정 + 방향 결정 (2026-06-21 세션 5)
적대적 리뷰의 "locator로 평탄화 불가" 결론을 측정으로 확정하고 "buffer pool과 뭐가 다른가"를 데이터로 답함.
- **측정1(BP 4G, table 1000행, held snapshot + 40s churn)**: deep analytic scan warm 0.0005s → deep **0.49s**, **물리 disk read=4(≈0)**, 논리 page 접근 **672만**. = 데이터가 buffer pool에 통째 상주(물리 read 0)인데도 느림 → **disk I/O 아님, CPU-bound**.
- **측정2(gdb sampling 40)**: deep scan **40/40 샘플**이 `row_search_mvcc`→`row_vers_build_for_consistent_read`→`trx_undo_prev_version_build`→`trx_undo_get_undo_rec`. = 그 CPU는 전부 **version chain reconstruction**(원래 주원인 row_search_mvcc 확정; `buf_page_get` 12뿐=page는 메모리·꺼내 parse하는 CPU가 지배).
- **측정3(BP sweep, 동일 워크로드)**: 4G→deep **0.49s**/read 4 · 64M→deep **75s**/read **60,667** · 16M→deep 70s/read 57,683. 작은 BP에서 **~150× 폭증**(undo page가 buffer pool 밖→deep scan이 6만 page disk read = **I/O-bound 전환**) + churn tps 18.9k→14.9k(undo page가 hot working set 밀어냄=pollution/HTAP 간섭).
- **방향 결정**: D는 consult-as-locator(점프)가 아니라 **version-level materialized cache**로 간다 — 재구성된 version image를 in-memory에(deadzone 제외 working-set만), **ephemeral**(durability/atomicity=InnoDB, crash 시 버리고 재구축), miss→InnoDB full walk fallback. 큰 BP에선 **재구성 CPU(672만 접근)**를, 작은 BP에선 **undo page disk I/O(6만 read)+pollution**을 제거. **다양한 메모리 환경(특히 작은 BP)에서 효과**가 baseline(DIVA류 "작은 메모리/buffer pool" 문제제기와 정합). buffer pool과 차별 = page 캐싱(version은 매번 재구성) vs **재구성 결과 캐싱(재구성 0회)**, 같은 메모리로 더 효율(필요 version만, undo page 전부 X).
- **ACID 정합**: 캐시는 authority 아님 — committed past version은 **immutable**(stale 없음; 무효화는 '아무 active reader도 안 봄'=메모리 관리뿐), isolation은 `changes_visible` 재현+InnoDB 최종 검증, uncommitted/rolled-back은 캐싱 안 함. buffer pool과 동일 위상(derived·ephemeral·miss→disk) — in-memory DB로 가는 게 아님.
- **개정 증분 계획(§4 테이블 D-2~D-4 대체)**: **D-2a** populate fix(version_trx_id=old DB_TRX_ID + writer_trx_id + undo_no + delete_mark + full PK 저장, epoch bucketing을 version_trx_id로) → **D-2b** `changes_visible` 정확 미러(오프라인 단위테스트, 4분기 경계) → **D-2c** consult shadow mode(consult+full walk 동시 실행해 roll_ptr/rebuilt version mismatch=0 검증; churn+LLT+rollback+forced collision) → **D-2d** authoritative locator(walk를 validated anchor로 short-circuit) → **D-3a/b/c** purge-view GC(1c-5 marked-ptr CAS 선행) → **D-4** per-snapshot materialized-version cache(D-0 곡선 실제 평탄화). **D-4 설계 전 ACID/correctness 적대적 검증 gate.**

## 13. D-4 정식 설계 — "완성 행 image를 deadzone-짧은 chain에" (2026-06-21 세션 5, walk 효율화 논의 결론)
§11이 "위치만 돌려주는 locator로는 평탄화 불가"(InnoDB가 어차피 재구성), §12가 측정으로 확증. 이후 walk 효율화 논의 결론: **diff 미러(=disk walk를 memory walk로)는 walk CPU를 못 줄이고, amortization(같은 snapshot 반복)은 OLTP가 매번 새 snapshot이라 비현실.** → **완성된 행 image를 우리 lock-free chain에 들고, deadzone로 chain을 짧게 유지하며, reader가 가시 image를 재구성 없이 반환.**

**핵심 통찰**: walk가 비싼 건 ① 가시 버전 *찾기* + ② 그 버전 *만들기*(disk fetch + diff 적용). 완성 image를 들면 ②가 사라지고(찾으면 바로 반환), 남는 ①은 deadzone로 chain이 이미 짧아 작다(이분 탐색·epoch 점프는 그 위 부가 최적화일 뿐, 지금 안 함). 위치만 최적화하면 ②가 남아 무의미(§11과 동일).

**설계**:
- **저장**: 버전 노드에 위치(space/page/offset)에 더해 **완성 행 image**(set-once immutable) + version_trx_id(가시성 키=old DB_TRX_ID) + writer_trx_id + delete_mark.
- **캡처(쓰기 흐름)**: populate hook(latch 하)이 그 시점 rec(=쓰기 직전 완성 행, old DB_TRX_ID를 가진 그 버전)를 ring 슬롯에 무할당 복사. **producer가 여러 InnoDB worker 스레드라 채널은 MPMC 유지(SPSC 아님)** — 그래서 가변 byte ring(여러 producer의 가변 영역 예약이 복잡·위험)을 새로 만들지 않고, **이미 검증된 고정 MPMC ring(`accel_ring.h`)의 슬롯에 상한 크기 image 칸을 더해** 스칼라+행 바이트를 함께 담는다(memcpy, img_len만큼만). **행이 상한을 넘으면 image 생략·위치만 enqueue → reader는 full walk fallback**(큰 행=off-page LOB은 어차피 캐싱 제외라 일치). 슬롯이 커지므로 ring capacity(N)는 그만큼 축소. off-latch drainer가 슬롯을 받아 노드 생성+image 적재; 재구성/InnoDB 접근 0(leaf domain 유지). D-1b "latch 하 무할당" 유지.
- **읽기(consult)**: reader가 (table,pk) chain에서 `changes_visible` 정확 미러로 가시 버전을 찾아 **그 노드 image를 바로 반환**(disk 0, diff 0). chain이 deadzone로 짧아 탐색도 짧음.
- **회수**: deadzone GC가 아무 active read view도 안 보는 버전 노드를 image째 EBR-retire → image 메모리가 살아있는 working-set으로 bounded.

**기존 틀 유지(사용자 제약)**: lock-free(image set-once → lock-free read 안전, 단일 drainer mutator) / epoch(구조 그대로, [min,max]는 탐색 점프 재사용) / deadzone(image 메모리 bound의 핵심, Stage C max 155) / disk-based HTAP(source of truth=InnoDB disk, image=derived·ephemeral·miss→full walk, in-memory DB 아님).

**이득/비용**: 이득 = 큰 BP 재구성 CPU(0.49s)+작은 BP undo disk I/O(75s/6만 read) 둘 다 제거, amortization 불필요(쓰기 때 모든 reader용으로 깔림). 비용 = 노드가 행 image를 들어 diff보다 메모리 큼 → deadzone bound + cold 버전은 image 생략·위치만+fallback 변형 가능.

**난제+해법**: 가변 행을 latch 하에 넘겨야 하고(drainer는 undo 직접 못 읽음=leaf domain) 새 가변 MP 링은 복잡·위험 → **검증된 고정 MPMC ring 슬롯에 상한 image 칸을 더해** 해결(상한 초과 행은 위치만+fallback, 슬롯 커진 만큼 N 축소).

**correctness 게이트(image에도 적용; ACID 적대적 검증 종합본 `d4_acid_synth.txt` 따름)**: changes_visible 정확 미러 + full PK collision 방어 + committed 버전만 캐싱(rollback 제외) + **off-page LOB·virtual generated column·instant-DDL·locking read 등은 image로 못 담거나 위험 → 캐싱 제외하고 full walk fallback**(MISS는 항상 correct). image라 roll_ptr 역참조가 사라져 purge/recycle 위험은 줄지만, 캡처 시점 committed 여부 게이트는 필요.

**구현 증분(image 중심, 작게)**:
- **① ✅** 고정 MPMC ring 슬롯에 상한 image 칸(`accel_ring.h`: `UndoRec`에 `img_len`+`img[ACCEL_IMG_MAX=512]`, enqueue/dequeue가 `offsetof(img)+img_len`만 부분복사; D-1b 고정-size static_assert 은퇴, trivially-copyable 유지). standalone 격리(`accel_ring_test.cpp`, `build_d1b2a.sh`) Release/ASan/TSan green, torn=0.
- **② ✅** populate hook이 행 image 캡처(`d1b1_patch.pl`: call site가 `rec`+`rec_offs_size(offsets)` 전달; `accel_on_undo`가 슬롯에 부분복사, 상한 초과는 위치만). mysqld build rc=0, churn 970k @ 32.3k tps(=vanilla), enq==drained·dropped=0 → image가 ring 통과.
- **③ ✅** drainer가 노드에 image 적재(`interval_list.h`: `undo_entry_node`에 `img`+dtor free=노드 수명과 동일=`retire_epoch_once`의 `delete e`에서 회수, 누수/UAF 0; `insert`가 image 복사). standalone 20 correctness Release/ASan/TSan green, mysqld build rc=0·churn 967k @ 32.2k tps·enq==drained=967660·dropped=0 → image가 ring→노드까지 end-to-end 적재. **= populate 경로 완성(쓰기쪽).** 커밋 `ebad8df`·`5057fea`·`a844e90`.
- **④ (읽기 연결 — 가장 큼·correctness-critical): 4a·4b ✅ (세션 6), 다음 = 4c.** 세부 설계·결과 = [design-D4b-shadow.md](design-D4b-shadow.md). **4a✅** `changes_visible` 4분기 정확 미러(`include/read_view_mirror.h`)+search predicate 교체+오프라인 단위테스트. **4b✅ SHADOW consult**: 4b-0 version_trx_id(=old DB_TRX_ID)/writer_trx_id 키 분리 → 4b-1 full-PK 식별 바이트+delete-mark+캡처 윈도우 `rec_offs_size`→`rec_offs_data_size`(M1) → 4b-2 per-key contiguity bookkeeping(`interval_list_header` atomic 2개) → 4b-3a `Accelerate_mvcc::consult()`(full-PK+changes_visible+contiguity, EBR Guard가 image 복사까지 span)+오프라인 6 테스트 → 4b-3b `row0vers.cc`에 SHADOW 배선+byte 비교(**hit_MISMATCH=0**, 12998/13000) → 4b-3c 적대적 매트릭스(60s LLT 29998/30000·rollback 안전MISS·강제충돌·동시성 ASan/TSan)+오프라인 negative control. consult=LOCATOR/HINT(모든 결과 HIT=vanilla byte 또는 MISS=full walk; silent wrong result 구조적 불가). standalone 32 green. 커밋 `1a79b83`~`ed3f757`. **다음 = 4c** 캐싱 제외 게이트(off-page LOB `rec_offs_any_extern`·virtual generated col `n_v_cols>0`·instant-DDL schema epoch·locking read `select_lock_type!=LOCK_NONE` 제외, committed만, full PK collision 방어, contiguity-to-head) → **4d** authoritative(walk skip, image 반환=성능 이득).
- **⑤** deadzone GC를 InnoDB purge view/trx_sys active view로 재구동(image 회수·메모리 bound; 1c-5 head marked-ptr CAS + epoch scalar atomic + EBR pool 사이징 선행).
- **⑥** 작은/큰 BP sweep에서 D-0 곡선(0.49s/75s) 평탄화 측정 = 최종 payoff.

재현 스크립트(레포 밖): mysqld `build_d2img.sh`(증분 patch+재빌드), ring 격리 `build_d1b2a.sh`, standalone correctness `build_test_1c6.sh`, BP sweep `d0_bpsweep.sh`.
