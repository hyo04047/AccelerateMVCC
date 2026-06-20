// Licensed under the MIT license.
//
// Stage D integration facade between InnoDB and the AccelerateMVCC in-memory index.
// Deliberately decoupled from both worlds: InnoDB calls these plain functions (no
// AccelerateMVCC/Kuku types leak into InnoDB headers), and the .cc owns the bridge.
//
// D-1a: populate hook is COUNT-ONLY (atomic counter + occasional stderr line) to prove the
// build wiring + that the call fires from real undo creation without destabilizing InnoDB's
// hot path. D-1b swaps the .cc body to actually insert (table_id, pk, trx_id) ->
// (space, page, offset) into the accelerator. D-2 adds a consult entry point.
//
// Canonical copy lives in this repo (integration/innodb/); build_d1*.sh copies it into the
// MySQL source tree (storage/innobase/include/) and patches trx0rec.cc + CMakeLists.

#ifndef ACCEL_HOOK_H
#define ACCEL_HOOK_H

#include <cstdint>

// Called from trx_undo_report_row_operation() right after the undo record's roll_ptr is built,
// on the success path. All ids widened to uint64 so the call site needs no casts.
void accel_on_undo(uint64_t table_id, uint64_t trx_id, uint64_t space_id, uint64_t page_no,
                   uint64_t offset, uint64_t op_type);

#endif  // ACCEL_HOOK_H
