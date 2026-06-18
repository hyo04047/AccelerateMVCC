#include "interval_list.h"

mvcc::UndoLogEntryNode::UndoLogEntryNode(uint64_t trxId, uint64_t spaceId, uint64_t pageId, uint64_t offset) {
    this->trxId = trxId;
    this->spaceId = spaceId;
    this->pageId = pageId;
    this->offset = offset;
}

void mvcc::update_epoch_node(epoch_node *epoch, uint64_t epoch_num, uint64_t trx_id, undo_entry_node *undo_entry,
                             epoch_node *next) {
    epoch->epoch_num = epoch_num;
    epoch->min_trx_id = trx_id;
    epoch->max_trx_id = trx_id;
    epoch->count = 1;
    epoch->first_entry = undo_entry;
    epoch->last_entry.store(undo_entry);
    // `epoch` is freshly allocated and not yet published to the list, so a plain
    // store of its forward pointer (unmarked) is sufficient. The publish happens
    // when the caller CASes/stores header->next to `epoch`.
    epoch->next.store(next, false);
}

mvcc::EpochNode::EpochNode(uint64_t epochNumber) {
    this->epochNumber = epochNumber;
}