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
| **D-0** | vanilla MySQL 8.4 소스 빌드(gcc 리스크 해소) + 기동 + sysbench **baseline** 측정 | mysqld 기동, sysbench OLTP+60s LLT 수치(우리 인덱스 없이) |
| **D-1** | accelerator를 InnoDB에 **링크**(라이브러리화) + **populate hook**(undo create 시 메타데이터 insert), read 경로는 미사용 | 기능 회귀 0, accelerator에 엔트리 쌓임 확인, 오버헤드 측정 |
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
