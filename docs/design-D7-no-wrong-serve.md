# design-D7 — no-wrong-serve 불변식: semi-formal 논증

상태: **논증 (세션13, Phase 3)**. 목적: 캐시가 authoritative serve(mode-1)에서 **틀린 행을 절대 서빙하지 않는다**는
주장을, 경험적 `construct_BAD=0`(여러 워크로드 관측)을 넘어 **구조적 불변식**으로 논증한다. 심사 제출은 아니나
심사 통과 기준(review-quality). 형식모델(TLA+/모델체크)은 향후 연구로 남기고, 여기서는 코드에 근거한 semi-formal
hand argument를 제시한다. 근거 코드: `accelerateMVCC.cpp::consult`, `read_view_mirror.h`, `interval_list.h`,
`integration/innodb/{accel_hook.cc, innodb-8.4.10-accel.diff}`. 관련: design-D4b-shadow §9·§13, design-D5-gc §10.

## 1. 설정 (definitions)

- 한 reader 트랜잭션이 ReadView **V** = (`up_limit_id`, `low_limit_id`, `creator_trx_id`, `m_ids`)를 쥔다(V는 reader가
  쥔 동안 immutable — InnoDB 계약).
- 한 clustered row(PK **k**)의 버전들은 InnoDB undo가 만드는 **lineage**(roll_ptr 체인)로 전순서(total order)를 이룬다:
  live-top L₀ → L₁ → L₂ → … (각 Lᵢ는 자신을 덮어쓴 writer가 있고, Lᵢ₊₁은 Lᵢ가 덮어쓴 직전 버전).
- **vanilla가 V·k에 대해 반환하는 답** = `v*(V,k)` = lineage를 live-top부터 내려가며 `changes_visible`이 처음 true인 버전.
- consult의 결과 공간: **HIT**(캐시 record R을 서빙) 또는 **MISS**{ABSENT, NOVISIBLE, NONCONTIG, INELIGIBLE, GCRACE}.
  serve 호출부(`row_vers_build_for_consistent_read`)는 **모든 비-HIT을 vanilla undo walk로 라우팅**한다(`accel_hook.cc`
  outcome 코드 0=HIT, 1..5=MISS; row0vers 패치가 HIT 외 전부 fall-through).

**증명 목표 (no-wrong-serve 불변식):**
> (T) HIT가 record R을 서빙하면 `R == v*(V,k)` (byte-for-byte). 그리고 (S) 비-HIT은 항상 vanilla walk로 fallback한다.
> 따라서 serve 결과는 **(HIT=증명상 정답) 또는 (MISS=vanilla 정답)** 둘 중 하나이고, **틀린 행은 결과 공간에 없다.**

## 2. 보조정리

**L0 (visible 버전의 유일성).** 고정된 V와 k에 대해, lineage 위에서 `changes_visible`이 true인 **가장 새 버전은 유일**하다.
∵ lineage는 trx-id로 매겨진 전순서이고 `changes_visible(id,V)`는 V의 4-분기 술어(아래 F2)다. v*는 "live-top부터 내려가
처음 visible"로 정의되므로 정의상 유일. (캐시가 동일 lineage 위에서 동일 술어로 "처음 visible"을 고르면 같은 버전.)

**L1 (HIT의 필요조건 — consult가 HIT를 내려면 아래 F1–F4가 모두 성립).** consult 코드 경로상:
- **F1 (full-PK identity).** production에서 `require_full_pk`가 강제 true(`allow_no_full_pk_` lock). 후보 노드는
  `u->pk_len==0`이면 skip, 아니면 reader의 full-PK 바이트와 **memcmp 일치**해야 후보가 된다. pk_hash는 Kuku 버킷 hint일
  뿐 권위가 아니다. ⇒ **후보는 reader가 찾는 바로 그 row(k)의 버전이다**(Kuku 충돌로 다른 row가 섞일 수 없음).
- **F2 (visibility = InnoDB 미러).** 후보의 visibility는 `read_view_mirror.h::changes_visible`로 판정되는데, 이는
  InnoDB `ReadView::changes_visible`의 4-분기(① id<up_limit ∨ id=creator → visible ② id≥low_limit → invisible
  ③ m_ids 비어있고 사이값 → visible ④ m_ids binary_search)를 **byte-exact 복제**한다. ⇒ **캐시가 visible로 고르는
  버전 = InnoDB 가시성 규칙이 visible로 고르는 버전.** (④의 전제 = m_ids 오름차순 정렬은 InnoDB 자체 계약이며, 세션13
  하드닝으로 consult 진입부에서 **release-active로 검사 → 미정렬이면 MISS_INELIGIBLE**[fail-closed]. NDEBUG서 컴파일아웃
  되는 assert에만 의존하지 않는다.)
- **F3 (동일 lineage·head 도달 = contiguity + link-gap).** HIT은 두 가지를 요구한다: (a) `contiguous_head_writer ==
  live_top_writer`(이미 latch된 top rec의 `row_get_rec_trx_id`) — 캐시의 gap-free run이 **live-top까지 닿음**의 증명;
  drainer-lag/최신 drop이면 불일치 → MISS_NONCONTIG. (b) Pass-2 chase가 live-top writer부터 **writer→predecessor
  링크(id-equality)** 를 따라 내려가며 처음 visible을 고른다 = **vanilla의 roll_ptr walk와 동일 경로**. 링크가 끊기거나
  (ring drop으로 인한 hole) ambiguous(한 writer에 서로 다른 두 predecessor = cross-generation 충돌)면 chase break →
  MISS_NONCONTIG. ⇒ **고른 버전은 vanilla가 걷는 그 lineage 위에 있고, 다른 세대(delete+reinsert)·끊긴 체인의 버전이
  아니다.** (`contiguous_suffix_min_version`은 vestigial — 실효 gate는 link-gap이 MISS로 demote하는 것.)
- **F4 (image fidelity = eligibility).** 서빙 바이트는 write 시점에 leaf X-latch 아래 캡처한 **전체 물리 레코드를 verbatim
  복사**한 것(in-page, ≤`ACCEL_IMG_MAX`, extern/virtual 없음). 4d-prep이 증명: 캐시 full-rec를 `rec_get_offsets`로 파싱한
  결과가 vanilla 재구성본과 (data_size 동일·memcmp data 동일·delete-flag 동일). off-page LOB/virtual/over-cap/over-out_cap은
  `img_len=0` 또는 serve out_cap 게이트로 **MISS_INELIGIBLE**. ⇒ **HIT의 서빙 record는 vanilla 재구성본의 byte-동일
  대체물이고, 부분/truncated image는 서빙되지 않는다.**

**L2 (over-approx만, under-approx 없음).** F1–F4 각각은 조건 불성립 시 **MISS 코드를 반환**하고 호출부가 vanilla walk로
보낸다. 즉 eviction/drop/gap/GC-over-prune/충돌 등 어떤 사유도 **HIT을 MISS로 demote(perf 손실)** 할 뿐, **틀린 HIT을
만들지 못한다.** (캐시는 InnoDB undo에서 derived된 비-권위 사본이므로, 캐시에 없거나 끊겨도 vanilla가 정답을 walk한다.)

## 3. 주정리 (T): HIT ⟹ R == v*(V,k)

F1∧F2∧F3∧F4가 성립하는 HIT를 가정. 서빙 record R(=고른 버전)은:
1. F1로 **row k의 버전**이고,
2. F3로 **vanilla가 걷는 k의 lineage 위에 있으며**(다른 세대·끊긴 체인 배제) **head까지 gap-free로 닿고**,
3. F2로 **그 lineage 위에서 V에 visible**이며, chase가 live-top부터 내려가 **처음 visible**을 골랐다,
4. F4로 **그 버전의 byte-동일 image**다.

(2)+(3)+L0에 의해, "k의 lineage 위에서 V에 visible한 가장 새 버전"은 유일하고 그것이 곧 `v*(V,k)`다. chase가 vanilla의
roll_ptr walk와 같은 경로·같은 술어로 같은 버전을 골랐으므로 **고른 버전 = v***. (4)로 **서빙 바이트 = v*의 바이트**. ∴ `R == v*`. ∎

## 4. 안전정리 (S): 비-HIT ⟹ vanilla, 절대 틀린 행 없음

L2에 의해 F1–F4 중 하나라도 불성립이면 consult는 MISS{ABSENT/NOVISIBLE/NONCONTIG/INELIGIBLE/GCRACE} 중 하나를 반환하고,
호출부는 **전부 vanilla undo walk**로 보낸다(= `v*` 정답). 따라서 실패는 **HIT→MISS demote**일 뿐 틀린 서빙을 만들지 못한다.
(T)+(S) ⇒ serve 결과 ∈ {증명상 정답 HIT, vanilla 정답 MISS}. **틀린 행은 도달 불가.** ∎

## 5. GC·동시성 상호작용 (serve-under-GC)

- **over-prune (GC가 reader에게 필요한 버전 회수).** lineage chase가 끊긴 노드에서 break → MISS_NONCONTIG → vanilla.
  캐시가 derived이므로 회수는 정답성에 영향 없음(perf-only). 이는 §2 L2의 특수 사례.
- **retire-가 probe와 race (TOCTOU).** mode-1 2nd firewall: `gc_generation`을 Guard-open 직후 snapshot, HIT 반환 직전
  recheck — 바뀌었으면 MISS_GCRACE → vanilla. (gen-gate는 **race detector**이지 over-prune detector가 아님 — 후자는
  F3 link-gap이 구조적으로 처리.)
- **UAF 없음.** per-traversal EBR Guard가 첫 deref 전에 취해지고 image 복사(caller 버퍼)까지 span한다(M2). retire는
  unlink 후 더 높은 epoch를 stamp하므로 Guard-보호 live traversal은 freed 노드에 도달하지 않는다. 생포인터는 facade 밖으로
  나가지 않는다.

## 6. mode별 2차 방어 (firewall이 load-bearing임을 분업으로 보강)

- **mode-2 (verify-serve).** 매 HIT마다 vanilla walk + byte-compare 후 일치할 때만 캐시 record로 교체. 즉 (T)를 **매 서빙마다
  런타임 재확인**(`construct_BAD`가 0이 아니면 vanilla 유지). 통합 전 워크로드서 construct_BAD=0 = (T)의 경험적 witness.
- **mode-1 (serve-only, walk skip = perf 경로).** 매-행 walk-compare가 없으므로 **구조적 F1–F4 + 보조 2차**에 의존:
  (R1) superseded_ts inversion = C1 inverted-superseded 오라클로 보수성 증명, (R2) same-writer cross-gen = F3 ambiguity
  guard, + 1-in-N **walk-audit**(런타임 표본, N=0이면 mode-1 거부→shadow) + gc_generation race backstop. "green gen-gate
  ≠ R1/R2 closed" — 정답성은 구조적 F1–F4(특히 F3 link-gap)에 서고, audit·gen-gate는 보강이다.

## 7. 잔여 표면 (정직)

- 본 논증은 **semi-formal hand argument**다. F1·F3·F4는 구조적, F2의 m_ids-정렬 전제는 세션13 release-active 가드로
  fail-closed, R1/R2는 오라클·ambiguity로 처리. 그러나 **형식모델로 기계검증된 것은 아니다** — TLA+/모델체크로 consult
  상태기계 + GC 상호작용을 검증하는 것은 **향후 연구**(REPORT §8).
- empirical `construct_BAD=0`은 (T)의 witness이되 1023/1024 미-audit HIT(mode-1)에 대한 확률 상한은 아니다 — 그래서
  구조적 논증(본 문서)이 필요하고, 둘이 상호 보강한다.
- 캐시 scope = in-page row(design-D6): off-page LOB는 F4 eligibility에서 제외(MISS), wrong-serve 표면이 아니라 coverage 한계.

## 8. 요약

| firewall | 막는 것 | 실패 시 |
|---|---|---|
| F1 full-PK memcmp | cross-row(Kuku 충돌) | skip → MISS |
| F2 changes_visible 미러(+m_ids 정렬 가드) | wrong-version 가시성 판정 | MISS_INELIGIBLE(미정렬) |
| F3 head_writer anchor + link-gap chase | cross-generation·끊긴 체인·head 미도달 | MISS_NONCONTIG |
| F4 verbatim image + eligibility | 부분/truncated/off-page image | MISS_INELIGIBLE |
| (GC) gc_generation + EBR Guard | retire race·UAF | MISS_GCRACE / 구조적 무-UAF |

**결론: F1∧F2∧F3∧F4 = HIT ⟹ 서빙 byte == vanilla(T); ¬(전부) ⟹ MISS ⟹ vanilla(S). 틀린 행은 결과 공간에 없다.**
캐시가 InnoDB undo에서 derived·비-권위라는 점이 모든 실패를 "느린 정답(vanilla walk)"으로 수렴시키는 근본 이유다.
