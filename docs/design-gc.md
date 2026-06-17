# 설계 문서 — GC(deadzone) & 동시성

> AccelerateMVCC의 GC·동시성 설계를 1차 자료(논문/실제 코드)에 근거해 확정한 문서.
> 이 파일은 "왜 이렇게 설계했나(추론·결정 포함)"를 담는다. 상태/로드맵은 [README](README.md), 이슈는 [findings](findings.md), 세션 기록은 [progress-log](progress-log.md).
> 최종 수정: 2026-06-18

---

## 1. 문제의식 (왜 이 GC가 필요한가)

vDriver 논문("Long-lived Transactions Made Less Harmful", SIGMOD'20) 문제 정의 = 우리 프로젝트 동기와 동일:
- MVCC는 불필요 버전을 **제때 제거**해야 함. 지연되면 version space 팽창 → 최악엔 시스템 정지/성능 붕괴.
- **LLT(long-lived transaction, OLAP)** 가 핵심 화근: LLT가 옛 버전을 살려두어 GC가 멈춤 → version chain 길어짐 → **throughput 붕괴**.
- in-row(PostgreSQL: heap page split) vs off-row(MySQL InnoDB: undo space, lookup 시 undo page I/O + **latch contention**). 우리 타깃 InnoDB는 off-row → 긴 chain traverse 시 undo page를 buffer pool로 읽는 I/O·오염·latch가 문제.
- vDriver 결론: "extended version chain is a prime culprit." 해법 = **version buffering(경량 인메모리 인덱스) + deadzone pruning + version classification.**

**우리 위치**: AccelerateMVCC = InnoDB undo log를 **직접 GC하지 않고**(I/O 비용↑), undo log **메타데이터(space/page/offset) 포인터만** 인메모리 epoch-list로 들고, 올바른 버전 위치를 빠르게 찾아주는 **가속 인덱스** + 그 인덱스를 compact하게 유지하는 **deadzone GC**. = vDriver의 "version buffer + deadzone"를 InnoDB 외부 인덱스로 변형. (in-memory hash+epoch-list 자체는 하태성 설계로 논문엔 없음; 문제의식·방향은 중복.)

> DIVA / One-shot GC 논문 기반 문제의식 종합은 §9에 추가 예정(백그라운드 정독 중).

---

## 2. deadzone GC 알고리즘 (vDriver 충실 + 코드 일치 확인)

**핵심(vDriver Theorem 3.1, Complete Version Pruning)**: live transaction 집합 T로부터 만든 dead zone 집합 Z_T에 대해, 한 버전은 **그 visibility가 어떤 dead zone에 완전히 포함될 때, 그리고 오직 그때만** prune 가능.

- **dead zone** = 연속한 두 live txn의 begin timestamp 사이의 "어떤 snapshot도 못 보는" 구간(hole). T 비면 Z_T={[-1,∞]} → 전체 즉시 회수.
- **판정식 일치(코드 레벨 확정)**:
  - vDriver `dead_zone.c` `IsInDeadZone`: `xmin > dz->left && xmax < dz->right`
  - 우리 `epoch_table.h` `can_pruning` (zone i): `range[2i] < v_start && v_end < range[2i+1]`
  - → **동일 공식.** 우리 코드는 vDriver 파생(§7 provenance).
- **dead zone 구성 일치**: vDriver는 각 백엔드가 snapshot을 공유 `thread_table`에 publish → updater가 주기적으로 **xmax 정렬 후 연속 active 사이 gap**으로 zone 생성(`MinInSnapshot` = 우리 low-limit). = 우리 `generate_dead_zone`.

**granularity: epoch = vDriver "version segment"**
- vDriver: 버전을 고정크기 segment로 묶고, `VS descriptor(seg_id, v_min, v_max)`로 **segment 통째 batch pruning**(`SegIsInDeadZone`).
- 우리: **epoch**(`EPOCH_SIZE` trx-id 묶음) 통째 prune. epoch `[v_start,v_end]` = segment `[v_min,v_max]`. → 우리 epoch-단위 GC(설계 결정 Q4)가 vDriver 방식과 정확히 일치.

**LLT를 어떻게 견디나**: 논문대로 — "LLT 직후 시작한 짧은 트랜잭션들이 commit되면 dead zone이 반복 **병합**돼 *wide dead zone*이 생김." → LLT가 바닥을 잡아도 그 위 구간이 통째 dead zone이 되어 prune 가능. 우리 deadzone 구성(연속 active 사이 zone)이 이미 이 병합을 표현. (vDriver는 추가로 버전을 **hot/cold/LLT 3분류**해 LLT가 잡은 것만 분리·나머지 batch clean — 대규모용 최적화, 우리는 §8 개선후보.)

---

## 3. 동시성 모델 (이번 라운드의 핵심 결정)

전제: epoch-list를 **lock-free로 설계한 것은 멀티스레드 환경을 처음부터 가정**한 것(하태성). 따라서 동시성 하드닝이 정당. 당시 설계엔 "Sync: Lock-free? Mutex? RCU? — 미정"으로 열려 있었음(6월 deck) → **지금 확정**.

### 3.1 두 개의 서로 다른 문제 (혼동 금지)
- **논리적 가시성(deadzone)**: "이 버전을 *필요로 하는* 트랜잭션이 있나?" — snapshot 기준, **트랜잭션 수명** 단위. LLT-tolerant(병합으로 구멍 잡음).
- **물리적 회수(reclamation grace)**: "이 노드 *메모리를 지금 밟고 있는* 스레드가 있나?" — 포인터 기준, **traversal(search 1회)** 단위. 매우 짧음.
- 둘은 **시간 척도가 다름.** 물리 문제에 논리(트랜잭션) 리스트를 쓰면 안 됨(아래 §3.3).

### 3.2 unlink 일관성 = marked pointer (Harris)
- 강의자료(Herlihy & Shavit, AtomicMarkableReference) "Problem" 슬라이드: 노드 c를 제거(앞 노드 next CAS) 하는 동시에 다른 스레드가 c 뒤에 d를 추가(c.next CAS)하면 **둘 다 CAS 성공해도 d가 유실**됨. 단일 CAS는 "제거 중인 노드에 끼워넣기"를 못 막음.
- 해결: `next`에 **포인터+mark bit을 한 워드로 같이 CAS**. 제거 = ① mark bit set(logical) ② 앞 노드 next CAS(physical). marked 노드 뒤 insert는 CAS 실패 → 유실 방지.
- C++엔 `AtomicMarkableReference`가 없으니 **marked pointer**(포인터 정렬 하위 비트에 mark 태깅, `std::atomic<uintptr_t>`)로 구현. → **(ii) 협조 FG unlink**(여러 스레드 동시 unlink)엔 필수.

### 3.3 reclamation = per-traversal EBR (per-transaction grace 폐기)
- 후보였던 "active transaction 리스트로 grace 판정(oldest_active > retire_ts면 free)"은 **틀림**: oldest_active가 LLT에 묶여 → deadzone이 논리적으론 지워도 된다 해놓고 **물리 free 단계에서 LLT-stall 부활** = 자기모순(deadzone의 존재 이유를 무력화).
- 올바름: grace를 **per-traversal(search 단위)** 로. LLT는 트랜잭션으로는 길지만 개별 search는 마이크로초 → retire된 dead epoch을 **LLT 살아있는 중에도 free 가능**. = **Epoch-Based Reclamation(EBR)**, RCU 계열(6월 deck의 RCU 후보가 정답).
- vDriver도 동일: Cutter가 dead segment **logical unlink** → 별도 GC 프로세스가 **`GetMinimumTimestamp` grace 확인 후 물리 free**. **vDriver grace = 우리 per-traversal EBR.**

### 3.4 FG / BG (설계서 그대로)
- 6·7월 deck: "FG = dead zone epoch을 list에서 제거→trash, BG = trash deallocate/reclaim. FG는 전체 list를 순회하지 않음." → FG(일반 traverse 스레드)가 만난 dead epoch을 협조적으로 unlink→retire, BG가 free.
- vDriver: 3개 BG 액터(deadzone updater / cutter / GC). prune은 처리 중(relocation) FG, 정리는 BG.
- 우리: **search 등 일반 traverse(FG)가 marked-pointer로 dead epoch unlink→retire** + **BG가 EBR grace 후 reclaim**. hot path(read/insert) lock-free 유지.

### 3.5 EBR 프리미티브 (구현·검증됨)
[`include/epoch_reclaimer.h`](../include/epoch_reclaimer.h) — `EpochReclaimer`: 전역 epoch + 스레드별 reservation 슬롯 + retire 리스트.
- Reader: `Guard`(search 진입/이탈)로 현재 epoch 예약.
- `retire(deleter)`: 현재 epoch 스탬프로 보관(아직 free 안 함). `reclaim()`: stamp < min(active reservation)인 것만 free.
- **검증**: `ebr_test` — 기본 의미 + 8-reader 동시 스트레스(50k swap), **ASan(UAF 0) / TSan(race 0) 클린.** (격리 단위검증 = Step 1a 첫 조각, 통합 전.)
- 현 단계 단일 producer(GC) 가정; 다중 producer(협조 FG)는 후속.

---

## 4. 설계 결정 기록 (open questions 해소)

- **Q1 list 방향**: insert(tail-prepend) ↔ GC(first→next 순회) 불일치 → **dummy=head 고정 + head-insert로 통일** + `epoch_node_wrapper.next` nullptr 초기화. (단일스레드 정확성용; 동시 unlink는 §3.2 marked pointer로.)
- **Q2 빈 snapshot**: vDriver는 "전체 즉시 회수" 허용. 우리는 보수적으로 "안 지움"(fast-path는 후속).
- **Q3 동시성 범위**: **단일스레드 정확성 먼저(B 완료) → 동시성 하드닝(현재)**. 프로젝트 원래 방침 "correctness first → lock-free later"와 일치.
- **Q4 granularity**: **epoch 단위** 유지 = vDriver segment pruning. (version 단위 sift는 큰 재설계, 범위 밖.)
- **GC warm-up**: epoch 25/50 early-return은 윈도잉상 의도된 것(50=이동, 75=prune)이라 보존. (종합 에이전트의 "50 mutation 스킵" 제안은 오류로 판명 → 기각.)

---

## 5. 동시성 구현 단계 (Step 1a~)

- **1a-i ✅**: per-traversal EBR 프리미티브 + 격리 ASan/TSan 검증. (커밋 250838a)
- **1a-ii (다음)**: 통합 — GC inline `delete` → `reclaimer.retire`, `search` 순회를 `Guard`로 감싸기, BG/주기 `reclaim()`. 단일 unlinker 유지. 검증: **LLT 떠 있어도 reclamation 진행됨** 테스트 + 기존 정확성/GC + ASan.
- **1b**: 협조 FG unlink(다중 unlinker) + **marked pointer**(§3.2). TSan.
- **1c**: 기존 `*multi_thread*_trx` 테스트 녹색화.

---

## 6. vDriver 실제 코드 매핑 (참고)

repo `github.com/hyu-scslab/vDriver_PostgreSQL`(branch `llt`, `#ifdef HYU_LLT`), `storage/vcluster/dead_zone.c`:
- `struct DeadZone {TransactionId left, right;}`, `DeadZoneDesc{dead_zones[], cnt}` (shared, `DeadZoneLock`).
- `RecIsInDeadZone`/`SegIsInDeadZone`(= 우리 record/epoch 판정), `IsInDeadZone: xmin>left && xmax<right`.
- snapshot publish: `thread_table.c` `SetSnapshot`/`ClearSnapshot` (GetSnapshotData 시).
- 회수: `CutVSegDesc`/`CutSegment`(logical unlink) + `GCProcessMain`(grace 후 `dsa_free`).
- 프로세스 기반(updater/cutter/GC 3개) → 우리는 스레드 + 인메모리 snapshot registry + EBR로 1:1 매핑.

---

## 7. provenance (출처)

- deadzone 알고리즘 = **vDriver 파생**(클린룸 재구현 아님). 7월 deck 원문 "extract dead zone detecting part from **vDriver InnoDB part**"(정승연 담당, vDriver의 MVCC/ReadView/Trx 추출·간소화). 판정식이 `IsInDeadZone`과 동일 → 확정.
- 역할: **하태성** = lock-free epoch list + simulator; **정승연** = Kuku 통합 + deadzone 추출.
- 조치: 보고서/코드에 **vDriver 출처·라이선스(PostgreSQL License) 표기** 권장. DIVA 공개 repo 없음(논문만); "DIVA 차용"은 인용 혼동.

---

## 8. 개선 여지 (3년 전 설계 그대로 안 가도 됨)

1. **tight한 segment 경계**: `can_operate_gc`가 epoch **명목 범위**(`epoch*SIZE~`)를 쓰는데, `epoch_node`엔 실제 `min_trx_id/max_trx_id`가 이미 있음 → vDriver `v_min/v_max`처럼 **실제 범위**로 판정하면 더 많이/정확히 prune.
2. **version classification (hot/cold/LLT)**: vDriver의 LLT 분리 batch clean — LLT 대규모 시 compact 유지에 유효. 후속 고려.
3. **빈 snapshot fast-path** (Q2), **dummy-list 누수 정리**.

---

## 9. literature 종합 (vDriver / DIVA / One-shot GC)

### 9.1 공통 문제의식 (through-line)
세 논문 + 우리 = 같은 적: **HTAP/LLT에서 MVCC version space 통제불능 팽창 + version 처리비용 폭증.**
- 진짜 killer = **GC 중 version traversal 비용**(write throughput에 비례 — 빨리 갈수록 벌받음; One-shot GC 정식화).
- **LLT가 tail-only GC 무력화**: global-min snapshot을 끝까지 붙잡아 in-middle dead version reclaim 불가 → chain unbounded.
- 공통 목표 = **LLT-tolerance / compact 유지**. 관통 통찰: version death는 **시간적으로 상관**(같이 시작→같이 끝) → per-version 정밀처리 대신 **epoch/segment batch** = 우리 epoch-list의 근본 근거.

### 9.2 방향성 스펙트럼
| | 핵심 무기 | 저장 | GC 단위 | LLT 대응 |
|---|---|---|---|---|
| vDriver | deadzone + SIRO + classification | disk | version-segment | deadzone in-middle reclaim |
| DIVA | index/data 분리 + epoch interval **tree** + macro/micro compaction | disk | epoch interval | tree 높이 ≤ **log(LLT lifespan)** |
| One-shot GC | temporality delta partition + **tagged pointer** | in-memory | start-time cohort | partition consolidation |
| **우리** | hash + epoch-list + deadzone | **in-memory 인덱스 / 데이터는 InnoDB undo** | epoch(=segment) | deadzone FG+BG |

**우리 좌표**: "disk MVCC(InnoDB) 위 **in-memory acceleration index**" — 독자 포지션(vWeaver "무개조" ~ DIVA "storage 개조" 사이). One-shot GC와 in-memory 인덱스는 공유하나 **우리는 metadata pointer만**(데이터 미소유) → "allocator reset=데이터 free" 트릭은 우리 *인덱스*에만 적용.

### 9.3 빌려오거나 개선할 것
1. **tagged pointer(epoch id+tag+offset)**: epoch reclaim을 `tag++` 한 번으로 O(1) implicit unlink + reader가 stale epoch 착지 시 tag mismatch로 self-invalidate → **구조적 reclamation 안전성**. → **EBR(§3.5) 보완/대체 후보로 평가 가치 있음.**
2. **min/max tight segment bound + sifting**: 명목범위 대신 실제 `min/max_trx_id`로 더 timely reclaim (= §8.1).
3. **multi-granularity 노드(capacity doubling + indirection)**: traversal hop bound + fragmentation↓.
4. **epoch 개수 = LLT-spread knob**: uniform엔 소수, LLT 강할수록 작고 많은 epoch로 in-middle 기회↑.
5. **(중장기) list → DIVA식 interval tree**: LLT 하 길이가 list→**log**(DIVA Thm 5.1)로 bound — "epoch-list compact" 목표의 정량 개선 축.
6. compaction 트리거 = live-interval 수 vs 인덱스 메모리 점유 discrepancy("gap indicator").

### 9.4 이미 정렬됨 (재고 X)
index↔data 분리 / epoch=GC단위=segment / deadzone 판정 / FG+BG / lock-free+EBR(또는 tagged pointer) / **ephemeral 인덱스**(crash 시 InnoDB undo가 source of truth → logging/recovery·update ordering 불필요, DIVA 논거 차용 가능).

### 9.5 차별화 명제 (향후 기여 주장용)
One-shot GC(§7.3.2)는 vDriver류 in-memory 인덱스를 "**dataset 비례 메모리 증가 → larger-than-memory 취약**"이라 비판. **우리 방어**: 데이터는 InnoDB undo에 두고 인덱스는 metadata pointer + epoch GC → compactness가 **dataset이 아니라 live-transaction window에만 비례**(DIVA Thm 5.1 정신). 이걸 보이면 그 비판을 무력화하며 "disk MVCC 위 in-memory accelerator" 포지션을 정당화.

---

## 10. stage C 실험 하니스 참조 (vDriver repo)

`github.com/hyu-scslab/vDriver` `PostgreSQL/Figure_12.../script_main.sh`:
- 워크로드: sysbench `oltp_update_non_index` (48 thread × 48 table × 1000 row, **Zipfian 1.2 skew**) = 소수 레코드 집중 업데이트 + **`BEGIN; SELECT; pg_sleep(60); COMMIT;` 60s long reader**(`repeatable read`로 snapshot 유지) + version-chain 길이 샘플러.
- 지표: **version-chain length CDF** (vDriver는 LLT에도 짧게 유지 vs vanilla 폭증). `INTERVAL_UPDATE_DEADZONE=0.1`(BG GC 주기).
- 우리 C단계 이식: writer N스레드 skew 업데이트 + reader 1 snapshot 유지 + chain 길이 측정. (in-memory thread 레퍼런스: `vWeaver_ermia` fork.)
