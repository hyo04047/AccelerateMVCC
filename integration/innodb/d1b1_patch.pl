s#\Q      accel_on_undo(index->table->id, trx->id, undo_ptr->rseg->space_id, page_no, offset, op_type);\E#      if (op_type == TRX_UNDO_MODIFY_OP && rec != nullptr) {
        uint64_t accel_pk = 1469598103934665603ULL;
        const ulint accel_nuk = dict_index_get_n_unique(index);
        for (ulint accel_i = 0; accel_i < accel_nuk; accel_i++) {
          ulint accel_len;
          const byte *accel_f = rec_get_nth_field(index, rec, offsets, accel_i, &accel_len);
          if (accel_len == UNIV_SQL_NULL) accel_len = 0;
          for (ulint accel_b = 0; accel_b < accel_len; accel_b++)
            accel_pk = (accel_pk ^ accel_f[accel_b]) * 1099511628211ULL;
          accel_pk = (accel_pk ^ accel_len) * 1099511628211ULL;
        }
        ulint accel_img_len = rec_offs_size(offsets);  /* D-4: full physical record size of the overwritten version */
        accel_on_undo(index->table->id, accel_pk, trx->id,
                      row_get_rec_trx_id(rec, index, offsets),
                      undo_ptr->rseg->space_id, page_no, offset, op_type,
                      reinterpret_cast<const unsigned char*>(rec), accel_img_len);
      }#;
