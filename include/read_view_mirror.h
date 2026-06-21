// Licensed under the MIT license.
#pragma once
#ifndef read_view_mirror_h
#define read_view_mirror_h

#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <vector>

// D-4 ④ (4a): an EXACT mirror of InnoDB's ReadView::changes_visible
// (storage/innobase/include/read0types.h). Stage D consult must decide a cached version's
// visibility with byte-for-byte the same logic InnoDB's consistent read uses, so that the image
// we return is the same version vanilla would reconstruct. We reproduce the 4-branch structure
// verbatim; the only omission is check_trx_id_sanity(), a UNIV_DEBUG assert / corruption guard
// that never changes the boolean result in a release build.
//
// Field semantics (from read0types.h):
//   id            = the trx id that created the version under test (its visibility key).
//   up_limit_id   = low-water mark: the view sees ALL ids strictly below this.
//   low_limit_id  = high-water mark: the view sees NOTHING with id >= this.
//   creator_trx_id= the viewing trx's own id (its own writes are always visible).
//   m_ids         = the set of RW transactions active when the snapshot was taken. InnoDB keeps
//                   this SORTED ASCENDING and binary_searches it -- callers MUST pass it sorted.
namespace mvcc {

inline bool changes_visible(uint64_t id,
                            uint64_t up_limit_id, uint64_t low_limit_id,
                            uint64_t creator_trx_id,
                            const uint64_t *m_ids, std::size_t m_ids_size) {
    // (1) below the low-water mark, or our own writes -> definitely visible.
    if (id < up_limit_id || id == creator_trx_id) return true;
    // (2) at or above the high-water mark -> started after our snapshot -> invisible.
    if (id >= low_limit_id) return false;
    // (3) between the marks with no active set -> committed before us -> visible.
    if (m_ids_size == 0) return true;
    // (4) between the marks: visible iff it was NOT one of the then-active RW transactions.
    return !std::binary_search(m_ids, m_ids + m_ids_size, id);
}

// Ergonomic overload: m_ids as a std::vector (must already be sorted ascending).
inline bool changes_visible(uint64_t id,
                            uint64_t up_limit_id, uint64_t low_limit_id,
                            uint64_t creator_trx_id,
                            const std::vector<uint64_t> &m_ids) {
    return changes_visible(id, up_limit_id, low_limit_id, creator_trx_id,
                           m_ids.data(), m_ids.size());
}

}  // namespace mvcc
#endif /* read_view_mirror_h */
