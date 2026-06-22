# D-4 ④ 읽기 연결 — 4b SHADOW consult 설계 (적대적 리뷰 대상)

> 상태: **4a✅·4b✅ 완료(세션 6)** — SHADOW consult 전부 구현·검증, **hit_MISMATCH=0**. 4b-0 `dcbd81f`
> · 4b-1 `0ba4781` · 4b-2 `4cda4f5` · 4b-3a `3f4ac95` · 4b-3b `5540ba7` · 4b-3c `ed3f757`(4a `1a79b83`).
> 결과 = §10. 배경/ACID 종합 = 레포 밖 `d4_acid_synth.txt`(22 confirmed). 캡처 방식 = **write-path**
> (design-D §13에서 확정, 구현 ③ 완료). **다음 = 4c**(캐싱 제외 게이트) → 4d authoritative.

## 0. 목표 (이 증분의 DoD)
InnoDB consistent read가 walk로 재구성한 visible 버전(`*old_vers`)과, 우리가 **쓰기 시점에 캡처한
pre-image**를 read 시점에 consult로 골라 **byte 단위로 비교**해 **mismatch=0**임을 churn + 60s LLT +
ROLLBACK + 강제 pk 충돌에서 입증. **결과는 쓰지 않는다(SHADOW)** — vanilla `*old_vers`를 그대로 반환.
correctness = visibility parity(= vanilla와 같은 버전·같은 바이트), no-crash 아님.

핵심 불변식(절대 제약): consult는 **LOCATOR/HINT**다. 모든 consult 결과는 둘 중 하나여야 한다 —
(a) **HIT** = vanilla와 byte 동일한 proven-boundary, (b) **MISS** = full walk fallback. 제3의 출력(틀린
값)은 구조적으로 불가능해야 한다. 메모리 eviction·drop·gap·제외는 HIT를 MISS로 바꿀 뿐, 절대 wrong
result로 바꾸지 않는다.

## 1. 캡처(write-path, 이미 구현됨 ③) — 4b에서 키만 교정
- 지점: `trx0rec.cc trx_undo_report_row_operation` 성공 경로, MODIFY-op, leaf X-latch 하. `rec` =
  **수정 직전 pre-image**(undo가 WAL상 먼저 기록되므로 `rec`는 아직 옛 값; `row_get_rec_trx_id(rec)` =
  **old_trx_id** = 이 pre-image 버전의 생성자).
- **4b-0 키 교정(현재 버그)**: 현재 `consume()`이 `r.trx_id`(=writer=`trx->id`)를 가시성 키로 insert에
  넘긴다. **가시성 키는 version 생성자 = old_trx_id여야 한다.** 노드가 두 id를 **구분**해 들도록:
  - `version_trx_id` = old_trx_id  (가시성 키 = changes_visible 판정 대상; epoch 배치도 이 값 기준)
  - `writer_trx_id`  = trx->id      (이 버전을 덮어쓴 자 = 다음-더-새 버전의 version_trx_id; contiguity·purge 게이트용)
  - standalone insert는 둘 다 같은 trx_id로(기본값) → 20 correctness 불변.
- **4b-1 full PK**: 현재 키는 pk_hash(FNV-1a 64bit)뿐. 충돌 방어 위해 **full PK 바이트**(상한
  `ACCEL_PK_MAX`)를 슬롯·노드에 같이 담아 consult가 memcmp. pk_hash = Kuku bucket hint, full PK =
  authority. (sysbench PK=INT라 수 바이트; 상한 초과는 image처럼 locator-only→MISS.)

## 2. contiguity primitive (load-bearing — boundary 정합성의 핵심)
InnoDB boundary = 전체 clustered chain에서 changes_visible인 **가장 새 버전**. 캐시는 구조상 불완전
(drainer lag·ring drop·일부만 캡처)하므로, **head까지 gap-free임을 증명할 때만** 캐시로 boundary를
정의한다. 아니면 MISS.

- **linkage 식**: entry E(version=old_trx_id, writer=W) → 다음-더-새 버전의 version_trx_id == W.
  따라서 인접 캐시 entry는 `E_newer.version_trx_id == E_older.writer_trx_id`이면 gap-free.
- **head 접점**: 최신 gap-free 캐시 entry의 `writer_trx_id`를 **contiguous_head_writer**로 둔다. consult
  시 row0vers.cc에서 **이미 latch된 top `rec`의 `row_get_rec_trx_id(rec)`(=live-top writer)** 를 읽어,
  `contiguous_head_writer == live-top writer`면 캐시가 head까지 contiguous(추가 latch·page access 0).
- **drainer 유지**: 단일 consumer가 key별 정렬된 immutable suffix를 잇는다. 새 entry가 suffix를 잇는지
  (version==직전 head의 writer) 확인. ring drop/gap → linkage 깨짐 → 그 key는 non-contiguous로 표시
  (contiguous_head_writer를 보수적으로 내리거나 무효화) → clean repopulate까지 consult MISS.
- **consult 판정**: 후보가 contiguous suffix 안에 있고 `next-newer 캐시 entry가 changes_visible 아님`
  (= boundary 조건) + `contiguous_head_writer == live-top writer`면 HIT. 하나라도 아니면 MISS.

## 3. SHADOW 배선 (read-path, 새 코드)
- 지점: `row0vers.cc:1249 row_vers_build_for_consistent_read`. vanilla가 `view->changes_visible(trx_id)`
  참인 `prev_version`에서 `*old_vers = rec_copy(buf, prev_version, *offsets)` 하고 break 하는 그 지점.
  여기서 우리는 (1) live-top writer = `row_get_rec_trx_id(rec)`(입력 top rec), (2) (table_id, full PK)
  = 입력 `rec`에서 populate와 **동일 FNV-1a over `dict_index_get_n_unique` fields**로 추출, (3) ReadView
  필드(up/low/creator/m_ids)를 가진다.
- ReadView 필드 접근: `read0types.h`에 minimal accessor 추가(up_limit_id/creator_trx_id/m_ids
  data+size) — PoC 패치. m_ids는 이미 정렬됨.
- consult facade(`accel_hook`, leaf-domain): `accel_consult(table_id, pk_hash, full_pk*, pk_len,
  up, low, creator, const uint64_t* m_ids, n, live_top_writer, out_img*, out_img_len*, out_ver*)` →
  분류 결과(enum: HIT/MISS_ABSENT/MISS_NONCONTIG/MISS_NOVISIBLE/MISS_INELIGIBLE) 반환. HIT면
  out_img/len/ver 채움(노드 image를 가리키되 **EBR Guard가 호출자 비교 구간까지 산다**).
- **byte 비교**: HIT면 `out_img_len == rec_offs_size(*offsets)` 확인 후 `memcmp(out_img, *old_vers,
  len)`. mismatch=0 기대. **EBR Guard 수명**: consult가 image를 가리키는 포인터를 반환하므로, 비교가
  끝날 때까지 Guard가 살아야 한다(finding: 'EBR copy after guard'). → facade가 비교까지 콜백/스코프로
  감싸거나, consult가 호출자 제공 버퍼로 image를 Guard 하에 복사해 반환. (4b shadow는 **Guard 하 복사
  후 비교**가 가장 안전.)
- **분류 카운터**: hit_match / hit_MISMATCH / miss_absent / miss_noncontig / miss_novisible /
  miss_ineligible. shutdown에 출력. **hit_MISMATCH=0이 게이트.** 나머지 miss는 정상(이번 워크로드에서
  설명 가능해야).

## 4. 이번 증분에서 켜는 최소 게이트(이외는 4c)
shadow byte-compare가 의미 있으려면 최소 다음이 필요(나머지 LOB/virtual/schema-epoch/purge-disowned/
DDL-flush/memory-budget는 sysbench oltp 워크로드가 안 건드리므로 **4c로 미룸** — 단 워크로드가 안
건드린다는 가정을 리뷰가 확인):
- (a) version 키 = old_trx_id (4b-0). (b) full-PK 비교 (4b-1, 강제 충돌). (c) contiguity 게이트 (4b-2,
  interior-hole). (d) committed-only: capture 시점 version_trx_id가 changes_visible의 committed 분기로만
  들어오게 — write-path capture는 pre-image가 이미 committed(현재 디스크 값)라 자연 충족이나, ROLLBACK은
  별도(아래).
- **ROLLBACK 처리(테스트에 포함)**: writer W가 rollback하면 pre-image(version=old)는 다시 current가
  된다. 노드는 여전히 version=old 버전을 가리키며 가시성은 old로 옳다(image라 dangling deref 없음).
  단 W가 만든 "다음-더-새 버전"은 사라지므로 **contiguity가 live-top과 안 맞아 자동 MISS**(W의 흔적이
  top에 없음). 즉 contiguity 게이트가 rollback을 흡수한다 — 리뷰가 이 논증을 검증.

## 5. 테스트 매트릭스 (mismatch=0 입증)
mysqld 통합 + sysbench. 모든 케이스에서 hit_MISMATCH=0, TSan/ASan(가능 범위) clean, enq==drained·
no-UAF:
1. **churn**: oltp_update_non_index 8thr 30s (hot rows, 깊은 chain).
2. **60s LLT**: 한 세션이 held snapshot으로 깊은 analytic scan 도는 동안 churn → consult가 깊은 visible
   버전을 골라 비교.
3. **ROLLBACK**: 일부 트랜잭션이 rollback/ROLLBACK TO SAVEPOINT → contiguity MISS로 흡수됨을 확인
   (hit_MISMATCH=0 유지, miss_noncontig 증가).
4. **강제 pk 충돌**: 서로 다른 PK가 같은 pk_hash를 갖도록 주입(테스트 훅) → full-PK memcmp가
   miss로 떨어뜨림(hit_MISMATCH=0). full-PK 끄면 mismatch>0이 떠야(게이트 음성 대조).

## 6. 4b 하위 증분 (작게 + 체크포인트, 각 독립 검증)
- **4b-0**: 노드에 version_trx_id/writer_trx_id 분리 + insert 시그니처 + consume 키 교정 + epoch 배치를
  version_trx_id로. VERIFY: standalone 24 green(기본값=동일), mysqld enq==drained·dropped=0.
- **4b-1**: ring 슬롯·노드에 full-PK 바이트(상한) + populate 캡처. VERIFY: mysqld churn enq==drained,
  PK 흐름 로그.
- **4b-2**: drainer contiguity bookkeeping(contiguous_head_writer/head_watermark, drop→무효). VERIFY:
  주입 drop/gap이 key를 non-contiguous로(거짓 contiguous 0).
- **4b-3**: ReadView accessor + consult facade + row0vers.cc shadow 배선 + Guard 하 byte 비교 + 카운터.
  VERIFY: §5 매트릭스 hit_MISMATCH=0.

## 7. 적대적 리뷰가 깰 것(이미 synth가 본 것 말고 **shadow 배선·신규 구조** 한정)
1. contiguity linkage 식(`E_newer.version==E_older.writer`, head==live-top writer)이 **모든** 갱신
   패턴(연속 update, 같은 트랜잭션 다중 update=같은 writer가 여러 version?, delete-mark, secondary→
   clustered 경로)에서 정확한가? 거짓 contiguous를 내는 시퀀스가 있나?
2. live-top writer를 `row_get_rec_trx_id(rec)`로 읽는 게 secondary-index 진입 경로에서도 옳은가(rec가
   clustered top인지)?
3. full-PK 추출이 populate(pre-image rec)와 consult(현재 top rec)에서 **동일 바이트**인가? non-key
   update는 PK 동일하나, **key update(InnoDB는 delete+insert)** 는 row identity가 바뀐다 — 그 경우
   캡처/판정이 어긋나나? (4c 영역이나 shadow에서 mismatch로 샐 수 있음)
4. byte 비교가 **REC_INFO_DELETED_FLAG·instant row-version 바이트**까지 포함하는가? delete-mark
   boundary에서 image의 in-record delete bit가 vanilla와 일치하나?
5. EBR Guard가 비교 구간까지 정말 사는가(Guard 하 복사 안 하면 evictor가 중간에 free → torn).
6. drainer가 head epoch scalar(min/max/count)를 in-place 변경하며 consult가 동시 읽기 → race(finding
   #18). shadow에서도 consult가 같은 hot key를 읽으니 발생. atomic/ready-flag 필요.
7. ROLLBACK이 정말 contiguity로 흡수되나, 아니면 hit_MISMATCH로 새는 시퀀스가 있나?
8. 강제 충돌 테스트가 실제로 full-PK 경로를 타는가(음성 대조: full-PK 끄면 mismatch 떠야).

## 8. 적대적 리뷰 결과 반영 (2026-06-22, 6렌즈 find→2각도 verify; go_with_conditions)
> 리뷰 워크플로(`wf_16b038a8`)는 verify 단계에서 hang(스트래글러 에이전트) → synthesis 미완. journal에서
> 6 find(~50 finding) + 84 verdict를 직접 추출·종합. **결론: GO-WITH-CONDITIONS** — shadow는
> LOCATOR/HINT 불변식(모든 결과가 counted-mismatch 아니면 safe-MISS, silent wrong result 0) 덕에
> 근본은 건전. 단 아래 must-fix 선반영.

**확정(confirmed) must-fix:**
- **M1 byte-compare 윈도우 버그 (high, 4b-1/4b-3)**: `rec` origin부터 `rec_offs_size` 비교는 데이터
  끝을 넘어 `extra_size`만큼 더 읽음 → 캡처는 옆 레코드 헤더, 읽기는 heap 버퍼 밖(ASan overflow) +
  page-relative 헤더(heap_no/n_owned/REC_NEXT)는 vanilla heap 재구성본과 절대 불일치. **단 sys
  컬럼(DB_TRX_ID/DB_ROLL_PTR)은 undo가 그대로 복원 → byte 동일(이건 안전, 헤드라인 'sys col 불일치'
  주장은 refuted).** → 비교·캡처를 **data payload(origin..origin+`rec_offs_data_size`)** 로 한정.
  단 delete-mark bit(REC_INFO_DELETED_FLAG)·instant row-version byte는 헤더(extra)에 있고 boundary
  correctness에 필요 → 캡처 시 명시적으로 같이 들고 비교에 포함(canonical range 정의). 캡처 길이도
  현재 `rec_offs_size`라 같은 over-read → 같이 수정.
- **M2 EBR Guard가 memcmp까지 산다 (blocker-class, 4b-3)**: facade가 `node->img` 생포인터를 돌려주고
  비교를 facade 밖에서 하면 Guard 해제 후 BG evictor가 free → UAF. **→ consult가 Guard 하에서
  caller 제공 버퍼로 image를 복사해 반환**(또는 Guard를 비교까지 잇는 스코프). 생포인터 반환 금지.
- **M3 atomic + ready-flag (high, 4b-0/4b-2/4b-3)**: drainer가 head epoch scalar(min/max/count,
  last_entry append)를 비원자 in-place로 쓰는데 consult가 같은 hot key를 동시 읽음 → data race(UB).
  metric(hit_MISMATCH)은 직접 안 깨고 HIT→safe-MISS거나 ASan/TSan에 잡힘. **→ consult가 읽는 필드는
  std::atomic release/acquire, image/태그는 다 쓴 뒤 ready flag 단일 release-store로 publish→consult가
  acquire-load 후에만 bytes 접근. contiguous_head_writer는 atomic `last_entry`에서 acquire-load로 유도.**
- **M4 full PK를 노드에 (blocker, 4b-1)**: 현재 `UndoRec`·`undo_entry_node`는 pk_hash(64bit)만 — full
  PK 바이트가 코드에 없음(설계만). 충돌 시 서로 다른 행이 한 chain에 섞임. **→ 슬롯과 노드 둘 다 full PK
  바이트 적재, consult가 memcmp(불일치→MISS).** consult의 FNV는 populate와 **per-field length-mix +
  n_unique 필드셋까지 동일**해야(아니면 bucket 라우팅 어긋남; full-PK가 authority라 최악은 MISS).
- **M5 version/writer 키 분리 (blocker, 4b-0)**: 현재 `consume()`이 writer(`trx->id`)를 가시성 키로
  넣어 모든 버전이 overwriter id로 판정됨(off-by-one). **→ version_trx_id=old_trx_id로 판정, writer는
  별도 저장**(=정확히 4b-0).
- **M6 테스트 adequacy (medium, 4b-3)**: ① 강제충돌 음성대조는 **결정적으로** byte-compare까지 도달해야
  (타이밍 의존이면 vacuous). ② race는 shadow 카운터만으론 TSan이 못 잡음 → **실제 동시 consult를 hot
  key에 돌려야** TSan에 노출. ③ `*old_vers==nullptr`(fresh insert/무이력)은 clean MISS로.

**기각(refuted)·완화 — 메모만:**
- contiguity 기계론적 공포 다수(same-writer 다중 update self-loop, ring-drop이 linkage를 bridge,
  drainer가 ring에서 순서 복원 불가, key-update 신원변경, within-epoch arrival order)는 **shadow
  metric상 refuted**: (a) byte-compare가 틀린 바이트를 counted-mismatch로 잡고 silent serve 안 함,
  (b) 서빙 버전을 고르는 건 contiguity가 아니라 `changes_visible` 필터. **단 이건 "shadow에선 안전"일
  뿐 — 4d(authoritative)에선 contiguity 정확성이 teeth를 가짐.** 그래서 4b-2는 구조(정렬된 immutable
  suffix + boundary)를 실제로 세워둔다(shadow가 관대해도).
- `rollptr/sys-col 불일치`: undo 복원으로 byte 동일 → refuted(M1으로 흡수).
- `uncommitted-preimage`, `rollback 흡수 window`: refuted(shadow에서 MISS거나 changes_visible가 막음).
- **단 ROLLBACK TO SAVEPOINT(`savepoint-rollback-false-hit`, split)**: live-top==contiguous_head라
  contiguity가 MISS로 못 떨굴 수 있음 → shadow면 byte-compare가 mismatch로 표시. sysbench는 savepoint
  안 씀(평소 미발생)이나 테스트 매트릭스에 별도 케이스로 두고, 4d 전 committed-only/re-anchor 게이트로 닫음.

## 9. 4b-2 contiguity 메커니즘 (구체 설계 — 코딩 전 사인 대상)
### 9.1 왜 필요한가 (shadow에서도)
consult가 고르는 "candidate"는 (table,full-PK 일치 + changes_visible인 가장 새 캐시 버전)이다. 캐시에
**interior hole**(candidate와 live-top 사이에 캐시 안 된 committed 버전 — ring drop이나 drainer-lag)이
있으면, consult가 더 오래된 candidate를 newest-visible로 오인 → byte-compare가 **mismatch**로 뜬다(캡처는
옳은데 *선택*이 틀림). 즉 contiguity 게이트가 없으면 shadow의 hit_MISMATCH가 0이 안 된다. 게이트는 그런
경우를 **MISS(full walk)** 로 떨궈 hit_MISMATCH=0을 만든다(안전 불변식: HIT는 항상 vanilla와 동일, 아니면 MISS).

### 9.2 핵심 단순화 — per-key arrival은 version 순서다
같은 row의 update는 InnoDB **clustered record X-lock**으로 직렬화된다(다음 writer는 이전 trx commit까지
대기). populate hook은 그 update의 modify 중(lock 보유) 발화하므로, 한 키의 enqueue는 **version 순서**로
일어나고 **FIFO ring이 보존**한다. → drainer는 키별로 버전을 **순서대로** 본다. (ring의 "순서 안 맞음"은
서로 **다른 키들** 사이에서만이고 per-key contiguity와 무관.) gap의 유일한 원천 = **ring drop(full)**.

### 9.3 linkage 불변식
entry E = (version_trx_id=V=이 버전 생성자, writer_trx_id=W=이 버전을 덮어쓴 trx = 다음-더-새 버전의 생성자).
→ 연속 두 캐시 entry는 **E_newer.version_trx_id == E_older.writer_trx_id** 이면 gap-free. drop으로 중간
버전이 빠지면 이 등식이 깨진다(다음 entry의 version != 직전 head의 writer).

### 9.4 drainer가 O(1)로 유지 (header에 atomic 2개)
per-key `interval_list_header`에 추가:
- `contiguous_head_writer` (std::atomic<uint64_t>): gap-free suffix가 head까지 닿을 때, 그 **최신 entry의
  writer**. (= cache가 닿은 "바로 아래 live" 버전을 덮은 trx.)
- `contiguous_suffix_min_version` (std::atomic<uint64_t>): 현재 gap-free run의 **가장 오래된 entry의 version**.

drainer가 새 entry E_new(=현재 키의 최신, version 순서)를 insert할 때 (release-store):
- 첫 entry이거나 `E_new.version_trx_id != contiguous_head_writer(현재)` → **gap/시작**: reset →
  `contiguous_suffix_min_version = E_new.version`, `contiguous_head_writer = E_new.writer`.
- `E_new.version_trx_id == contiguous_head_writer(현재)` → **extend**: `contiguous_head_writer = E_new.writer`
  (min 유지).
self-update(같은 trx 다중 update)는 V_2==W_2==trx_id이고 V_2==E_1.writer라 extend로 자연 처리(리뷰의
self-loop 우려는 이래서 무해 — 기각과 일치).

### 9.5 consult의 contiguity 게이트 (4b-3에서 사용)
read site에서 `L = row_get_rec_trx_id(rec)`(이미 latch된 clustered top). candidate(table+full-PK 일치 +
changes_visible 최신)가 **boundary로 인정**되려면 (acquire-load):
1. `contiguous_head_writer == L` (캐시가 live-top까지 gap-free로 닿음 — drainer-lag/최신 drop이면 불일치 → MISS),
2. `candidate.version_trx_id >= contiguous_suffix_min_version` (candidate가 gap-free run 안 — 그 아래 hole 무관),
3. (full-PK memcmp 일치 — 4b-1).
셋 다 충족 → **candidate가 증명된 newest-visible boundary = HIT**. 하나라도 아니면 **MISS → full walk**.
candidate **위쪽**만 gap-free면 됨(그 아래는 더 오래돼 무관). drop된 구역의 reader는 ②/③에서 걸러 MISS.

### 9.6 동시성 (M3)
header의 두 scalar는 단일 writer(drainer) release-store / consult acquire-load = atomic. node의
version/writer/pk/img는 set-once 후 chain publication(기존 `header->next`/`last_entry` release store)으로
가시화 → consult가 acquire 후 읽으면 안전. **consult는 epoch min/max/count(비원자, GC용)는 안 읽는다**
(4b-3에서 그 필드 touch 금지) → 그 pre-existing race는 consult 경로 밖. EBR Guard는 byte-compare까지 산다(M2).

### 9.7 4b-2 범위/검증
- 구현: `interval_list_header`에 atomic 2개 + drainer(=insert) 유지 로직. standalone은 단일 키·version
  순서라 자연 충족(무회귀). consult는 아직 없음(4b-3) — 이 증분은 **bookkeeping만**.
- 검증: standalone 24 green(구조 추가만, 동작 불변) + mysqld populate enq==drained·dropped=0. drop 주입
  (작은 ring으로 강제 drop)해서 gap 발생 시 contiguity가 reset되는지 카운터로 확인(거짓 contiguous=0).
  단, drop 주입 케이스는 4b-3 consult 카운터에서 더 자연스럽게 검증되므로 4b-2에선 로그 레벨로만.

## 10. 4b 결과 (세션 6, 완료) — 모든 hit_MISMATCH=0
consult가 고른 버전이 InnoDB 재구성 visible 버전과 byte-동일; 안 맞은 건 전부 안전 MISS(full walk).
- **standalone (Release/ASan/TSan, 32 tests green)**: `ReadViewMirror.*`(4분기 경계) · `Consult.*` —
  HIT+image 일치, drainer-lag/interior-drop→MISS, 충돌 full-PK 필터, no-visible, ineligible, 동시성
  consult‖insert race/UAF 0, **negative control**(full-PK OFF면 cross-row 오답 = 가드 작동 증명).
- **mysqld (4G BP, held-snapshot reader ‖ churn)**: 평상 `calls=13000 hit_match=12998 hit_MISMATCH=0
  noncontig=2`; **60s LLT** `29998/30000, mismatch 0`(~1800 versions/row); **rollback 폭풍**
  `hit_match=616 mismatch 0 noncontig=13384`(롤백→live-top 되돌아가 contiguity 불일치→안전 MISS);
  **강제 충돌**(ACCEL_PK_MASK_BITS=6) full-PK ON/OFF 둘 다 mismatch 0이나 contiguity가 먼저 전부 MISS
  → mysqld 음성대조는 **vacuous**(리뷰 M6 함정) → negative control은 오프라인으로.
- **must-fix 처리**: M1(data-payload 비교 윈도우)✅·M2(EBR Guard가 image 복사까지 span)✅·M3(contiguity/노드
  필드 atomic; consult는 GC용 min/max/count 안 읽음)✅·M4(full-PK, consult FNV=populate 동일)✅·M5(version/
  writer 분리)✅·M6(동시 consult TSan·결정적 negative control)✅.
- **재현**: `build_test_4b3.sh`(standalone 32)·`build_d4b3b.sh`(shadow)·`build_d4b3c.sh`(매트릭스). row0vers/
  read0types/trx0rec 패치는 build script가 멱등 적용(MySQL 소스라 repo에 vendor 안 함).

## 11. Coverage 측정 (세션 6, shadow) + 알려진 한계
shadow 카운터로 측정한 **coverage = hit_match/calls**(4d 없이 측정 가능; 4d는 성능 이득용). 표준 HTAP
analytic-pain 워크로드(보유-스냅샷 깊은 reader ‖ churn, `build_cov.sh`):
| 조건 | hit율 | hit_MISMATCH | noncontig | ring dropped |
|---|---|---|---|---|
| 4G BP / 8 writer   | 13000/13000 = **100%**   | 0 | 0 | 0 |
| 4G BP / 32 writer  | 12996/12998 = **99.98%** | 0 | 2 | 0 |
| 256M BP / 8 writer | 12998/13000 = **99.98%** | 0 | 2 | 0 |
→ 표준 벤치(sbtest, 일반 컬럼)에서 깊은 읽기 coverage ≈ 100%, **쓰기 폭주·작은 BP에도 견고**(dropped=0,
hit율 불변). coverage는 BP 크기와 무관(hit율은 "버전이 캐시에 contiguous하냐"지 BP가 아님). MISS는
0.02%(순간 drainer-lag)뿐 → 그 워크로드에선 walk I/O·pollution 악순환을 사실상 다 끊음(필요조건 확인).

**⚠️ 알려진 한계 — 최종 테스트/검증 시 반드시 점검**:
1. **LOB/text-heavy 워크로드 coverage**: 위 측정은 sbtest(일반 컬럼)라 100%. off-page LOB·virtual 컬럼
   행은 4c-1에서 캐싱 제외(→ MISS) — 현장 HTAP analytic이 wide TEXT/BLOB 위주면 coverage가 떨어지고,
   그 행들은 walk I/O 문제가 그대로 남는다(MISS=문제 회귀, +공유 BP pollution 외부효과). 최종 검증은
   **LOB 비중이 있는 워크로드에서 hit율·실제 I/O 감소를 측정**할 것. 필요하면 LOB 본문까지 캡처해 coverage
   확대(InnoDB 깊은 작업).
2. **instant-DDL 테이블 (4c-2 ✅)**: consult-side 거친 게이트 — reader의 테이블 `current_row_version>0`이면
   MISS(가속 포기). 진단: per-entry 캡처-epoch는 틀린 신호(consult는 reader-era 값을 봄: populate_max=1
   but consult_live_max=0 — held-snapshot reader가 pre-ALTER 정의를 쥠) → reader-era 신호로 전환.
   검증(ALTER 먼저→post-ALTER reader): gate ON t_alt 6500 ineligible-MISS·t_norm 6500 HIT·mismatch 0,
   gate OFF t_alt도 HIT(E↔F 차=t_alt 6500=게이트 발화 직접 증거). 드물어 우선순위 낮음. real cross-era
   byte-위험 negative control은 staging(미커밋 writer interleaving) 난이도로 best-effort.
3. 위는 **coverage(hit율)** 측정 — **실제 I/O/지연 감소(성능)** 는 4d(walk skip)+⑥(작은 BP에서 D-0
   0.49s/75s 곡선 평탄화)에서 측정. coverage~100%는 "4d면 깊은 읽기 거의 다 skip"의 필요조건.
