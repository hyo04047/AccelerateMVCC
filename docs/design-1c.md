# 설계 문서 — Step 1c (FG 협조 unlink, 풀스코프)

> 1c = reader(FG)도 dead epoch을 **물리적으로 떼어내고 회수에 참여**시켜 read-heavy 구간에서도 버전 체인을 짧게 유지. 보류 #1·#2·#5를 1c 안에서 흡수(풀스코프 — [[scope-prefer-full-for-performance]]).
> 이 계획은 9에이전트 설계 워크플로(위험요소 4축 → 종합 → 적대적 검증 4관점)로 도출·하드닝됨. 적대적 검증이 종합안을 4관점 모두에서 깼고(전부 holds=false), 그 구멍을 아래에 반영. 최종 수정: 2026-06-19.

---

## 0. 핵심 한 줄
종합안의 **중심(회수-한-번 상태기계 + 공유 디스크립터 수명)은 검증에서 못 깸 = 건전**. 깨진 건 전부 **가장자리**: ① head epoch 가지치기 vs 진행 중 append (진짜 논리 구멍, 3개 관점이 독립 지적) ② 증분 순서(전부-CAS 먼저, 백스톱 먼저) ③ 단일 회수 권한 일원화 ④ 자료구조/굶음/seq_cst 위생. 스코프 축소 없이 **순서와 불변식만** 조이면 닫힘.

## 1. 두 리스트가 한 노드를 공유 — 1c의 본질
- **버전 체인**(레코드별, header→epoch→…, reader 순회 대상, 길이가 벤치 지표): 1c에서 **다중 unlinker**(reader들 + BG).
- **부기 리스트**(epoch_table 버킷별 wrapper 체인, reader 안 봄, BG가 prune/회수에 사용): **단일 unlinker(BG)** 로 유지.
- 한 epoch_node는 **두 리스트에서 동시에 도달 가능** → **두 리스트 모두에서 떨어진 뒤 정확히 한 번** 회수해야 함. 이게 1c의 크럭스.

## 2. 회수-한-번 프로토콜 (스파인, 검증 통과)
- epoch_node에 **상태 도장**: `LIVE → CHAIN_DETACHED → RETIRED`.
- 버전 체인에서 누가(FG든 BG든) 노드를 splice하면 → mark + CAS-splice 후 상태를 `CHAIN_DETACHED`로 CAS하고 **멈춤(절대 회수 안 함, wrapper 안 건드림)**.
- **회수(free)는 단일 액터 BG가, 부기 wrapper를 떼는 순간에만**, `state.exchange(RETIRED)`로 게이트해 **정확히 한 번**. exchange가 이전값 RETIRED를 돌려주면 skip.
- 안전 근거: wrapper splice는 chain detach보다 항상 나중 + chain mark로 새 reader는 이미 skip → 회수 stamp가 모든 live reservation보다 큼(EBR grace).
- **결과**: reader는 epoch_node를 **절대 retire 안 함**(다중-producer 회수 위험 소멸), BG는 freed 노드를 **절대 deref 안 함**.

### 2-A. 적대적 수정: 상태 도장이 **유일한 회수 권한**
종합안은 메인 wrapper-sweep에만 게이트를 명시하고 다른 회수 지점(BG chain-splice, dummy-overflow drain/re-home, 백스톱)을 "descriptor-dead면 회수"로 서술 → 한 노드가 **2개 wrapper에서 도달**(insert가 버킷-swap 레이스 때 같은 epoch_node를 dummy에도 wrap)하면 게이트 안 거친 지점이 **이중 free**.
→ **모든 epoch_node 회수 지점을 단 하나의 헬퍼**(`state.exchange(RETIRED)!=RETIRED일 때만 retire`)로 일원화. **descriptor-dead만으로 회수하는 경로 0개.** wrapper 객체는 별도 할당이라 wrapper별 독립 회수는 정상(단, wrapper도 물리적으로 떨어진 뒤에만).

## 3. 진짜 논리 구멍 (헤드라인) — head prune vs 진행 중 append
**문제(검증 3개 관점이 독립 지적, blocker)**: insert가 head epoch에 **제자리 추가(append)** 할 땐 레코드 락만 잡고 **head 포인터(header→next)는 안 건드림**. BG의 head 가지치기는 header→next CAS로만 조율 → BG는 그 단어를 안 쓰는 append와 **무동기**, 게다가 BG는 레코드 락도 안 잡음. → BG가 head를 prune+retire하는 사이 insert가 **freed 노드에 append(write-after-free) + 그 insert 유실**. 또한 insert의 head 읽기는 **EBR Guard 밖**.

**수정(#5를 올바르게)**:
1. **head는 "더 새 epoch이 앞에 끼어 head 자리에서 밀려난 뒤"에만 prune** — `header→next.ptr()!=E`가 먼저 참이 되어야. 즉 #5의 cold-head 회수를 **'head 아님'에 게이트**(절대 'head가 dead'에 게이트하지 않음). 등가로 "sealed epoch floor"(아직 append 가능한 최신 epoch보다 **엄격히 오래된** epoch만 prune).
2. insert의 **head 접근(head 읽기 + append 분기) 전체를 EBR Guard로** 감싼다(head prune을 켜는 바로 그 증분에서).
3. **head 포인터 writer를 insert + BG 둘로 제한**(FG는 head 절대 안 건드림 — FG는 head를 prune도 help-splice도 안 함). BG head-prune은 **단일 시도 후 양보**(insert에 지면 더는 dead-newest 아님 → 포기, 다음 사이클). → 3자 경합/라이브락 제거.

## 4. 그 외 가장자리 수정 (순서·자료구조·위생)
- **B. 전부-CAS 먼저**: 버전 체인의 모든 물리 쓰기(내부 predecessor + head 케이스)를 **CAS로 바꾼 뒤에야 FG 떼기를 켠다**. 평문 store와 다중 unlinker 공존 금지(종합안은 FG 떼기를 head-CAS 전에 켜 lost-splice 창을 냄).
- **C. 백스톱을 FG 떼기보다 먼저**: 윈도 청소는 각 버킷을 **사이클당 한 번만** 봄 → 백스톱(전-버킷 청소) 없이 FG가 cold 버킷 노드를 detach하면 **그 노드는 영원히 회수 안 됨(무한 누수)**. "BG가 backstop"은 전-버킷 청소가 생기기 전엔 거짓. → 백스톱을 detach보다 먼저 랜딩.
- **D. 부기 리스트 단일-unlinker 강제 or CAS화**: wrapper splice 평문 store는 unlinker가 정확히 하나일 때만 유효. 윈도/백스톱/drain이 모두 wrapper를 건드리므로 **단일 BG 액터 안에서 직렬화(별도 helper 스레드 금지) + 범위 disjoint + 상태-게이트 헬퍼 경유**(겹쳐도 idempotent), 또는 wrapper splice도 Harris CAS화.
- **E. 부기 집합 자료구조**: mid-vector erase + cold-미배수 버킷 누적 → 백스톱이 **무한 스캔 + 인덱스 산술 깨짐**. → tombstone-in-place(push-only, tombstone skip) 또는 **별도 'pending-detached' 리스트**(비용 ∝ 미회수 detached 수, 0으로 수렴).
- **F. 회수 굶음 vs LLT**: EBR 회수는 **가장 오래된 reservation**에 묶임 → 60초 LLT가 reservation을 길게 잡으면 survivors 무한 적체. → LLT는 **논리적 read-view는 길게, 물리적 reservation은 search 한 번 단위로 짧게**(per-traversal EBR 본의 — design-gc §3.3). C 하니스에서 LLT Guard를 sample 사이에 반드시 해제. survivors high-water assert.
- **G. dummy-overflow drain**: insert_to_dummy를 **단일 head 원자에 Treiber push**로(BG는 같은 원자 exchange로 detach), 실패-CAS inserter가 완전 reload하게 → lost wrapper 없음. drain된 wrapper·옛 dummy head는 **EBR로 retire**(raw delete 금지).
- **H. slot lease 오버플로 핀 seq_cst**: 오버플로 min-reservation 원자는 deref 전에 **seq_cst store**, min 계산에서 **seq_cst load**로 `min(m, overflow)` 폴드(1b #5 하드닝과 동일 규율). lease 반납은 reservation=NOT_READING 뒤 fence 후 slot-free.
- **I. staleness oracle 보강(낮은 확신)**: 단조 trx-id 덕에 내부 gap zone은 새 txn이 못 쪼갬 → stale 디스크립터는 **덜 청소할 뿐 과청소 안 함**(검증이 못 깸). 단 re-home/append 경로는 단조 논증이 안 덮으므로 1c-1 oracle이 그 경로도 시험. re-home 시 **현재** 디스크립터로 deadness 재검증.

## 5. 검증이 못 깬 것 (= 핵심 건전, 재고 X)
상태-도장 회수-한-번 자체 / 공유 디스크립터 EBR 수명(exchange-then-retire, Guard 안 load) / 단조 trx-id → 과청소 없음 / FG 내부 splice 유한(prev 보유, idempotent mark, 시도 cap + BG backstop) / 1c-0·1c-1·1c-2 독립 시험성.

## 6. 재배열된 증분 (각 독립 빌드·ASan/TSan 검증)
| # | 목표 | 흡수 | 핵심 검증 |
|---|---|---|---|
| **1c-0** | EBR **slot lease**(per-thread 임대, 종료 시 반납) + 오버플로 핀 **seq_cst**(§4-H). 기존 1b 워크로드, 인덱스 동작 변경 0. | #1 | thread-churn(>pool 순차 + 동시): UAF 0, slot 실제 재사용, 오버플로 핀 경로 hit. 기존 9개 green. |
| **1c-1** | 공유 deadzone 디스크립터 **publish(원자 swap)+옛 것 EBR 회수** + FG **판정만**(unlink X). | — | publish‖판정 readers: 디스크립터 UAF/이중free 0. staleness oracle(re-home/append 포함, §4-I). |
| **1c-2** | epoch_node **상태 도장 + 단일 상태-게이트 회수 헬퍼(유일 권한, §2-A)** + 버전 체인 **전 물리 쓰기 CAS화**(내부+head 단어, §4-B) + 부기 splice CAS화/단일-unlinker 계약(§4-D). **아직 BG-only unlinker.** | — | 상태 전이 보존 카운터(LIVE=CHAIN_DETACHED+RETIRED+live) HARD assert. 누수 회귀 0. run_gc_once 회귀. |
| **1c-3** | **전-버킷 백스톱 청소** + 부기 집합 tombstone/별도-리스트(§4-E) + dummy-overflow drain(§4-G). 전부 BG-only, 상태-게이트 경유. **(detach보다 먼저, §4-C)** | #2 | detect_leaks=1: 버킷-swap 레이스로 dummy 적재 후 quiescence에 dummy≈0, 영구 누수 0. |
| **1c-4** | **FG 협조 unlink 켬(NON-head만)**: mark+CAS-splice 내부 + `CHAIN_DETACHED`, retire/​head 절대 X. | — | hot record(skew) reader‖reader, reader‖BG: UAF/race 0, **hot 체인 실제 축소**, 가시성 불변(대조 쿼리 동일). 라이브락 0. |
| **1c-5** | **BG cold dead-head prune**: 'head 아님'/sealed-floor 게이트 + 레코드 락/floor로 append와 직렬화 + insert head 접근 **Guard** + BG **단일시도-양보**(§3). | #5 | no-lost-insert oracle(모든 undo 엔트리 계수), cold head 결국 회수(체인→empty), UAF/race 0. |
| **1c-6** | 스케일/통합: 고스레드 skew 전경로 동시. LLT는 **짧은 per-search Guard만**(§4-F). | — | TSan race 0 + ASan UAF/이중free 0 + Release no-hang. 가시성 oracle 통과 + 체인 축소 + 오버플로 핀 안전. survivors high-water. |

핵심 재배열(종합안 대비): **전부-CAS(1c-2)·백스톱(1c-3)을 FG 떼기(1c-4)보다 앞**으로, **회수 권한 단일화**, **head-prune 직렬화 수정**, **head writer 2자 제한**, **부기 집합 tombstone**, **LLT 짧은 Guard**.

## 7. 1c-2 구현 적대적 코드리뷰 (3 reviewer) — 하드 제약 2건
1c-2 구현(retire-once state machine + version-chain CAS unlink)을 reviewer 3명이 공격. **1c-2 코드 자체는 contract(BG 단독 unlinker, node당 swept wrapper 1개, GC-skips-head)에서 정확** — reviewer 3은 insert/search 상호작용을 못 깸, reviewer 1은 `unlink_epoch_from_chain`이 1c-2·1c-4 양쪽에서 정확함을 확인. 발견 2건은 전부 **지금은 inert인 forward-looking 함정**이며 후속 증분의 하드 제약:

- **[1c-3, high] retire-once gate는 `en->state` 안에 산다 → `en`이 살아있는 동안만 idempotent.** 두 번째 retire 시도가 `en` EBR-free 이후 `en->state`를 읽으면 그 자체가 UAF(안전한 skip 아님). 지금 안전한 이유 = **node당 swept wrapper가 정확히 1개**(`insert`가 epoch당 wrapper 1개; dummy-overflow wrapper는 sweep 안 됨). **→ 1c-3의 dummy-overflow drain은 그 단일 소유권을 *transfer*(re-home = wrapper 이동)해야 하고, 살아있는 node에 *두 번째 swept wrapper*를 만들면 안 됨.** 또 wrapper는 그 node가 retire되기 전에 list에서 splice-out돼야(이후 sweep이 retire된 node에 재도달 금지). (정 안 되면 retire-once 토큰을 `en` 밖으로 빼는 fallback.) → 코드 주석 정정 완료(가짜 ">1 wrapper 안전" 문구 제거).
- **[1c-5, low] head-prune 켜기 전 insert의 head-prepend(`header->next` plain store)를 CAS로 바꿔야.** 안 그러면 `unlink_epoch_from_chain`의 header-predecessor 분기(현재 GC-skips-head로 dormant)가 insert의 plain store와 경쟁해 retire된 node를 resurrect + UAF. = §3의 "head writer 2자 제한"을 코드 레벨로 못박은 것.

- (참고) conservation `detached==retired`는 *single swept wrapper* 불변식에서만 성립 — 두 번째 swept wrapper 세계가 오면 3-term(LIVE+CHAIN_DETACHED+RETIRED)으로. 주석 정정 완료.

## 8. 1c-4 구현 적대적 코드리뷰 (3 reviewer) — blocker 2건 수정
1c-4(FG cooperative unlink, version chain이 처음으로 multi-unlinker가 되는 payload)를 reviewer 3명이 공격. reviewer 3(retire/UAF/conservation)은 **못 깸**(strand/double-free/UAF/conservation 다 건전). 나머지 둘이 **blocker 2건** 발견 — 둘 다 수정 완료:

- **[blocker, chain corruption] stale successor.** FG splice가 node를 mark하기 *전에* 읽은 `succ`로 pred를 CAS-splice. 그 사이 다른 unlinker가 `epoch->next`를 바꾸면 `set_mark`은 실패하는데 코드가 그 반환을 무시하고 stale `succ`로 splice → live node를 chain에서 떨어뜨리고 이미 detach된(곧 free될) node를 chain에 되살림 → UAF. **수정**: `set_mark` 후 `epoch->next`를 다시 load해, 실제로 marked일 때만(=next가 frozen) 그 re-read한 successor로 splice; 아니면 splice 없이 advance. (marked node의 next는 frozen이라 help-splice 경로는 원래 안전했음 — prune 경로만 결함.)
- **[blocker, visibility = 깊은 것] deadzone over-prune (tight bounds).** `can_operate_gc`가 epoch의 **nominal 범위** `[epoch*SIZE, +SIZE)`를 그 epoch의 visibility 끝(xmax)으로 씀. 실제 xmax는 그 version을 덮는 다음-newer version의 begin-ts인데, nominal은 이걸 과소평가 → reader(특히 LLT)가 아직 보는 version을 dead로 오판해 prune. **pre-existing**(BG도 같은 check → 잠복; visibility를 GC 하에서 검증하는 테스트가 없었음), **1c-4가 reader 경로에서 결정적으로 증폭.** 이건 프로젝트 핵심인 **LLT correctness**를 깨는 거라 ship 불가.
  - **수정 = tight bounds** (design-gc §8.1을 correctness 필수로 끌어올림): epoch_node에 `superseded_ts`(다음-newer version begin-ts; head는 UINT64_MAX) 추가 — insert가 새 epoch을 prepend할 때 옛 head에 O(1) store(보수적으로 prepend trx_id). `can_prune_epoch`이 `[min_trx_id, superseded_ts]`(실제 visibility)로 판정 → vDriver SegIsInDeadZone 충실. **FG·BG 둘 다** `can_prune_epoch` 경유라 한 곳 수정으로 양쪽 fix. 회귀 테스트 `GcDeadzone.TightBoundDoesNotOverPruneNeededVersion`(nominal에서 FAIL → tight에서 PASS로 경험적 확인). `GcDeadzone`/staleness oracle 헬퍼는 fields를 nominal로 세팅해 기존 단언 유지. 17개 Release/ASan/TSan green.
