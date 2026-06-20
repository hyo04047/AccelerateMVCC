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
| **D-1b-2b** | ring을 accel_hook에 배선(hook=enqueue) + **off-latch drainer 스레드**(pop+count, 진짜 insert 아직 X) + init/shutdown 생명주기 + ready gate | mysqld multi-conn 안정, drop counter, clean shutdown |
| **D-1b-3** | drainer가 **진짜 single-consumer insert**(Trx_manager/get_mutex 미사용, ctor 사전생성 제거, kuku≥1<<16, return 계약, **GC off**) | chain integrity per (table,pk), insert==drained, 유계 메모리 |
| **D-1b-4** | 하드닝: noexcept hook 감사, assert-no-malloc-on-latch, accel=leaf-domain 불변식 | full build, mysqld boot, latch-hold 회귀 0 vs D-1a |
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
