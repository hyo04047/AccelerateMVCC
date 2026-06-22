// Licensed under the MIT license.
//
// Stage D integration facade between InnoDB and the AccelerateMVCC in-memory index.
// Deliberately decoupled from both worlds: InnoDB calls these plain functions (no
// AccelerateMVCC/Kuku types leak into InnoDB headers), and the .cc owns the bridge.
// accel is a LEAF lock domain: this code must never include an InnoDB header or call back
// into InnoDB (keeps the InnoDB->accel edge one-way -> no cross-domain latch cycle).
//
// D-1a: count-only (proved wiring).
// D-1b-1 (current): the call site now extracts the clustered PK (hashed -> pk_hash) and the
//   prior version's DB_TRX_ID (old_trx_id), and filters to MODIFY-op only. Body is still
//   count-only -- this increment just validates the KEY PLUMBING (row-unique keys) before any
//   shared data structure is touched. D-1b-2 adds a lock-free ring + off-latch drainer; D-1b-3
//   makes the drainer do the real single-consumer insert.
//
// Canonical copy lives in this repo (integration/innodb/); build_d1*.sh copies it into the
// MySQL source tree (storage/innobase/include/) and patches trx0rec.cc + CMakeLists.

#ifndef ACCEL_HOOK_H
#define ACCEL_HOOK_H

#include <cstdint>

// Lifecycle (D-1b-2b). Call accel_init() ONCE at InnoDB startup (off any latch, after the trx
// subsystem is up -- end of srv_start) to start the off-latch drainer thread; call
// accel_shutdown() at InnoDB shutdown (start of srv_shutdown) to stop+join it. Do NOT rely on a
// static destructor. Both are no-ops if already (un)initialized; safe to call once each.
void accel_init() noexcept;
void accel_shutdown() noexcept;

// Called from trx_undo_report_row_operation()'s success path (MODIFY-op only), after the undo
// record's roll_ptr is built, WHILE InnoDB holds the clustered leaf-page X-latch. D-1b-2b: this
// only ENQUEUES the scalar record into a bounded lock-free ring (noexcept, no alloc, no lock,
// full -> drop, never block); the off-latch drainer does the real work. pk_hash = hash of the
// clustered PK fields (row identity); old_trx_id = the DB_TRX_ID of the record being overwritten
// (= begin-ts of the version this undo reconstructs, the visibility key D-2 will need).
//
// D-4: img/img_len carry the row image of the version being overwritten (the version this undo
// reconstructs), captured at the call site. The hook copies up to ACCEL_IMG_MAX bytes into the ring
// slot under the latch (alloc-free prefix memcpy); rows larger than the cap pass img_len=0 ->
// stored locator-only -> consult falls back to a full walk. Pass img=nullptr/img_len=0 if absent.
// D-4 4b-1: img must be the DATA payload (rec_offs_data_size from the record origin), NOT
// rec_offs_size -- the latter over-reads extra_size past the row (M1). pk/pk_len carry the FULL
// clustered-PK identity bytes (length-prefixed fields) so consult can memcmp past a pk_hash
// collision (over cap -> pk_len=0 -> consult MISS). delete_mark = REC_INFO_DELETED_FLAG of the
// captured version (carried explicitly because the data-payload image excludes the record header).
void accel_on_undo(uint64_t table_id, uint64_t pk_hash, uint64_t trx_id, uint64_t old_trx_id,
                   uint64_t space_id, uint64_t page_no, uint64_t offset, uint64_t op_type,
                   const unsigned char *img, uint64_t img_len,
                   const unsigned char *pk, uint64_t pk_len, uint64_t delete_mark,
                   uint64_t extra_len) noexcept;

// D-4 4d-prep: consult FETCH (shadow). Called from row_vers_build_for_consistent_read on the
// NON-locking consistent-read path with the row key (table_id + pk_hash + full PK bytes extracted
// exactly like the populate hook), the reader's ReadView fields, the live row's last writer, and the
// reader's schema epoch. Returns the consult outcome (0=HIT, 1=MISS_ABSENT, 2=MISS_NOVISIBLE,
// 3=MISS_NONCONTIG, 4=MISS_INELIGIBLE) and bumps the outcome counters. On HIT it copies the cached
// FULL physical record into out_buf UNDER the EBR Guard (data origin at out_buf+*out_extra,
// *out_len = full rec length). The caller (InnoDB domain) then builds a rec_t from it and compares
// to vanilla -- the cache result is NOT served yet (4d-prep proves the construction in shadow).
int accel_consult_fetch(uint64_t table_id, uint64_t pk_hash,
                        const unsigned char *pk, uint64_t pk_len,
                        uint64_t up_limit_id, uint64_t low_limit_id, uint64_t creator_trx_id,
                        const uint64_t *m_ids, uint64_t m_ids_n,
                        uint64_t live_top_writer, uint64_t live_schema_epoch,
                        unsigned char *out_buf, unsigned int out_cap,
                        unsigned int *out_len, unsigned int *out_extra) noexcept;

// D-4 4d-prep: the caller reports whether the rec_t it built from the fetched image matched vanilla's
// rebuilt *old_vers (data bytes + delete flag + valid offsets). matched!=0 -> construct_ok else
// construct_bad. The gate is construct_bad==0 with construct_ok == HIT count.
void accel_note_construct(int matched) noexcept;

// D-4 4d-2: authoritative SERVE mode, read once from ACCEL_AUTHORITATIVE at accel_init.
//   0 = OFF (shadow; the walk's vanilla answer is served, cache only compared).
//   1 = serve-only: on HIT the caller builds *old_vers from the cached image and SKIPS the walk
//       (the performance path -- this is what flattens the D-0 curve).
//   2 = verify-serve: the caller still walks to rebuild vanilla, byte-compares, and ONLY then serves
//       the cache-built record (proves every served answer == vanilla; no walk-skip, no perf gain).
// The caller gates serving on n_v_cols==0 (virtual-column rows are never cached, 4c-1) and, in mode 2,
// on the byte-compare matching (mismatch -> keep vanilla -> never a wrong row).
int accel_authoritative_mode() noexcept;

// D-4 4d-2: the caller reports it actually served a cache-built record for this consult HIT. The gate
// for a serve run is served == HIT count (every HIT served), with construct_bad==0 in mode 2.
void accel_note_serve() noexcept;

#endif  // ACCEL_HOOK_H
