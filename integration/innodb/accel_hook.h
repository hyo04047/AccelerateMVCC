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
void accel_on_undo(uint64_t table_id, uint64_t pk_hash, uint64_t trx_id, uint64_t old_trx_id,
                   uint64_t space_id, uint64_t page_no, uint64_t offset, uint64_t op_type) noexcept;

#endif  // ACCEL_HOOK_H
