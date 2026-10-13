-- =====================================================================
-- Uji otomatis seluruh aturan bisnis. Setiap uji dijalankan dalam
-- sub-transaksi yang selalu di-rollback, jadi data asli tidak berubah.
--   select * from run_ledger_tests();
-- Kode XT000 = uji gagal (aturan tidak ditegakkan), XT001 = uji lulus.
-- =====================================================================
create or replace function run_ledger_tests() returns table (test text, result text, detail text)
language plpgsql as $$
declare
    v_hdr   bigint;
    v_stock int;
    v_amt   numeric;
    v_j     json;
    v_cash  numeric;
begin
    test := 'T01 Jurnal tidak seimbang ditolak (dikirim langsung, tanpa frontend)';
    begin
        insert into journal_headers (trx_date, ref_no, description) values (current_date, 'T01', 'uji') returning header_id into v_hdr;
        insert into journal_lines (header_id, account_id, debit, credit) values (v_hdr, acc_id('6104'), 100000, 0), (v_hdr, acc_id('1102'), 0, 90000);
        set constraints all immediate;
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T02 Baris debit = 0 dan kredit = 0 ditolak';
    begin
        insert into journal_headers (trx_date, ref_no, description) values (current_date, 'T02', 'uji') returning header_id into v_hdr;
        insert into journal_lines (header_id, account_id, debit, credit) values (v_hdr, acc_id('6104'), 0, 0);
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T03 Nominal debit negatif ditolak';
    begin
        insert into journal_headers (trx_date, ref_no, description) values (current_date, 'T03', 'uji') returning header_id into v_hdr;
        insert into journal_lines (header_id, account_id, debit, credit) values (v_hdr, acc_id('6104'), -5000, 0);
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T04 Hapus akun yang sudah dipakai jurnal ditolak (ON DELETE RESTRICT)';
    begin
        delete from chart_of_accounts where account_code = '1103';
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T05 PURCHASE menambah stok dan menjurnal Dr Persediaan / Cr Utang Usaha';
    begin
        select stock_qty into v_stock from inventory_items where item_id = 'BRG-04';
        insert into inventory_transactions (item_id, trx_type, qty) values ('BRG-04', 'PURCHASE', 10);
        select l.debit into v_amt from journal_lines l join journal_headers h using (header_id)
         where h.ref_no = 'INV-' || lpad(currval('inventory_transactions_trx_id_seq')::text, 6, '0') and l.account_id = acc_id('1301');
        if (select stock_qty from inventory_items where item_id = 'BRG-04') = v_stock + 10 and v_amt = 125000 then
            raise exception using errcode = 'XT001', message = format('stok %s -> %s, Dr Persediaan %s', v_stock, v_stock + 10, v_amt);
        end if;
        raise exception using errcode = 'XT000', message = 'stok/jurnal tidak sesuai';
    exception when sqlstate 'XT001' then result := 'PASS'; detail := sqlerrm;
              when others then result := 'FAIL'; detail := sqlerrm;
    end;
    return next;

    test := 'T06 SALE melebihi stok ditolak (anti-negative inventory)';
    begin
        select stock_qty into v_stock from inventory_items where item_id = 'BRG-01';
        insert into inventory_transactions (item_id, trx_type, qty) values ('BRG-01', 'SALE', v_stock + 1);
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T07 SALE mengurangi stok dan menjurnal Dr HPP / Cr Persediaan = qty x unit_cost';
    begin
        select stock_qty into v_stock from inventory_items where item_id = 'BRG-01';
        insert into inventory_transactions (item_id, trx_type, qty) values ('BRG-01', 'SALE', 2);
        select l.debit into v_amt from journal_lines l join journal_headers h using (header_id)
         where h.ref_no = 'INV-' || lpad(currval('inventory_transactions_trx_id_seq')::text, 6, '0') and l.account_id = acc_id('5101');
        if (select stock_qty from inventory_items where item_id = 'BRG-01') = v_stock - 2 and v_amt = 2 * 185000 then
            raise exception using errcode = 'XT001', message = format('stok %s -> %s, Dr HPP %s', v_stock, v_stock - 2, v_amt);
        end if;
        raise exception using errcode = 'XT000', message = 'stok/jurnal tidak sesuai';
    exception when sqlstate 'XT001' then result := 'PASS'; detail := sqlerrm;
              when others then result := 'FAIL'; detail := sqlerrm;
    end;
    return next;

    test := 'T08 UPDATE jurnal POSTED ditolak';
    begin
        update journal_headers set description = 'diubah' where ref_no = 'SA-202610';
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T09 DELETE jurnal POSTED ditolak';
    begin
        delete from journal_headers where ref_no = 'SA-202610';
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T10 Ubah nominal baris jurnal POSTED ditolak';
    begin
        update journal_lines set debit = debit + 1
         where header_id = (select header_id from journal_headers where ref_no = 'SA-202610') and debit > 0;
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T11 Voucher kas keluar tidak seimbang ditolak oleh RPC';
    begin
        perform post_cash_voucher('{"trx_date":"2026-10-13","prepared_by":"uji","counterparty":"uji","description":"uji",
          "lines":[{"account_code":"6104","debit":50000,"credit":0},{"account_code":"1102","debit":0,"credit":40000}]}');
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T12 Voucher tanpa kredit akun kas ditolak';
    begin
        perform post_cash_voucher('{"trx_date":"2026-10-13","prepared_by":"uji","counterparty":"uji","description":"uji",
          "lines":[{"account_code":"6104","debit":50000,"credit":0},{"account_code":"2101","debit":0,"credit":50000}]}');
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T13 Voucher melebihi saldo kas ditolak';
    begin
        perform post_cash_voucher('{"trx_date":"2026-10-13","prepared_by":"uji","counterparty":"uji","description":"uji",
          "lines":[{"account_code":"6105","debit":99000000,"credit":0},{"account_code":"1102","debit":0,"credit":99000000}]}');
        raise exception using errcode = 'XT000';
    exception when sqlstate 'XT000' then result := 'FAIL'; detail := 'tidak ditolak';
              when others then result := 'PASS'; detail := sqlerrm;
    end;
    return next;

    test := 'T14 Voucher valid: POSTED, created_by terisi, hash valid';
    begin
        v_j := post_cash_voucher('{"trx_date":"2026-10-13","prepared_by":"Penguji","counterparty":"Toko ATK Sumber Rejeki","description":"Beli map arsip",
          "lines":[{"account_code":"6104","debit":60000,"credit":0},{"account_code":"1102","debit":0,"credit":60000}]}');
        if (verify_journal((v_j ->> 'header_id')::bigint) ->> 'hash_valid')::boolean
           and (select created_by = 'Penguji' and status_posting = 'POSTED' from journal_headers where header_id = (v_j ->> 'header_id')::bigint) then
            raise exception using errcode = 'XT001', message = format('%s hash %s…', v_j ->> 'ref_no', left(v_j ->> 'hash_checksum', 16));
        end if;
        raise exception using errcode = 'XT000', message = 'status/hash tidak sesuai';
    exception when sqlstate 'XT001' then result := 'PASS'; detail := sqlerrm;
              when others then result := 'FAIL'; detail := sqlerrm;
    end;
    return next;

    test := 'T15 Storno membalik saldo kas; storno kedua ditolak';
    begin
        select sum(debit - credit) into v_cash from journal_lines where account_id = acc_id('1102');
        v_j := post_cash_voucher('{"trx_date":"2026-10-13","prepared_by":"Penguji","counterparty":"uji","description":"salah input",
          "lines":[{"account_code":"6104","debit":70000,"credit":0},{"account_code":"1102","debit":0,"credit":70000}]}');
        perform reverse_journal((v_j ->> 'header_id')::bigint, 'salah akun', 'Penguji');
        if (select sum(debit - credit) from journal_lines where account_id = acc_id('1102')) <> v_cash then
            raise exception using errcode = 'XT000', message = 'saldo kas tidak kembali';
        end if;
        begin
            perform reverse_journal((v_j ->> 'header_id')::bigint, 'ulang', 'Penguji');
            raise exception using errcode = 'XT000', message = 'storno kedua tidak ditolak';
        exception when sqlstate 'XT000' then raise;
                  when others then null;
        end;
        raise exception using errcode = 'XT001', message = format('saldo Kas Kecil kembali ke %s; storno ganda ditolak', v_cash);
    exception when sqlstate 'XT001' then result := 'PASS'; detail := sqlerrm;
              when others then result := 'FAIL'; detail := sqlerrm;
    end;
    return next;

    test := 'T16 Manipulasi langsung (trigger dimatikan DBA) terdeteksi oleh hash_checksum';
    begin
        alter table journal_headers disable trigger trg_journal_header_guard;
        update journal_headers set description = description || ' (dimanipulasi)' where ref_no = 'SA-202610';
        alter table journal_headers enable trigger trg_journal_header_guard;
        if not (verify_journal((select header_id from journal_headers where ref_no = 'SA-202610')) ->> 'hash_valid')::boolean then
            raise exception using errcode = 'XT001', message = 'hash_valid = false setelah deskripsi diubah';
        end if;
        raise exception using errcode = 'XT000', message = 'manipulasi tidak terdeteksi';
    exception when sqlstate 'XT001' then result := 'PASS'; detail := sqlerrm;
              when others then result := 'FAIL'; detail := sqlerrm;
    end;
    return next;
end $$;

revoke execute on function run_ledger_tests() from public, anon, authenticated;
