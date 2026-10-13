-- =====================================================================
-- SOAL 2 — PT Diponegoro Logistik Utama: persediaan perpetual
-- Trigger memutakhirkan stok + jurnal Persediaan/HPP dalam transaksi yang sama.
-- =====================================================================

-- Struktur tabel sesuai naskah soal (tidak diubah)
create table inventory_items (
    item_id    varchar(10) primary key,
    item_name  varchar(100),
    stock_qty  int not null default 0,
    unit_cost  numeric(15, 2) not null
);

create table inventory_transactions (
    trx_id    serial primary key,
    item_id   varchar(10) references inventory_items (item_id),
    trx_type  varchar(10) check (trx_type in ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty       int not null,
    trx_date  timestamp default current_timestamp
);

-- Lapisan kedua: walaupun trigger dilewati (mis. UPDATE manual), stok tetap tidak bisa negatif.
alter table inventory_items add constraint ck_stock_non_negative check (stock_qty >= 0);

-- ---------------------------------------------------------------------
-- 2.1  Trigger function
--   Konvensi qty: PURCHASE & SALE selalu positif; ADJUSTMENT bertanda
--   (+ = selisih lebih hasil opname, - = susut/rusak).
--   Jurnal otomatis (nilai = |mutasi| x unit_cost):
--     PURCHASE        Dr Persediaan (1301)         Cr Utang Usaha (2101)
--     SALE            Dr HPP (5101)                Cr Persediaan (1301)
--     ADJUSTMENT (+)  Dr Persediaan (1301)         Cr Selisih Persediaan (5102)
--     ADJUSTMENT (-)  Dr Selisih Persediaan (5102) Cr Persediaan (1301)
--   shortcut: sisi pendapatan penjualan (Dr Kas/Piutang, Cr Penjualan) tidak dijurnal karena
--   tabel soal tidak punya harga jual; tambahkan kolom unit_price bila modul penjualan dibuat.
-- ---------------------------------------------------------------------
create or replace function trg_update_stock_and_journal() returns trigger
language plpgsql as $$
declare
    v_item    inventory_items%rowtype;
    v_delta   int;
    v_amount  numeric(18, 2);
    v_dr      smallint;
    v_cr      smallint;
    v_hdr     bigint;
begin
    if new.trx_type in ('PURCHASE', 'SALE') and new.qty <= 0 then
        raise exception 'Qty % harus > 0 (diterima %)', new.trx_type, new.qty;
    elsif new.trx_type = 'ADJUSTMENT' and new.qty = 0 then
        raise exception 'Qty ADJUSTMENT tidak boleh 0';
    end if;

    -- 2.2  Kunci baris item (row-level lock). Transaksi lain untuk item yang sama
    --      menunggu di sini sampai transaksi ini COMMIT/ROLLBACK, lalu membaca stok terbaru.
    select * into v_item from inventory_items where item_id = new.item_id for update;
    if not found then
        raise exception 'Item % tidak terdaftar', new.item_id;
    end if;

    v_delta := case when new.trx_type = 'SALE' then -new.qty else new.qty end;

    -- 2.1.b  Anti-negative inventory
    if v_item.stock_qty + v_delta < 0 then
        raise exception 'Stok % (%) tidak cukup: tersedia %, keluar %',
            v_item.item_id, v_item.item_name, v_item.stock_qty, -v_delta
            using errcode = 'P0001', hint = 'Transaksi dibatalkan (anti-negative inventory).';
    end if;

    -- 2.1.a  Mutasi stok
    update inventory_items set stock_qty = stock_qty + v_delta where item_id = new.item_id;

    -- Jurnal perpetual: nilai persediaan di buku besar ikut berubah saat itu juga
    v_amount := abs(v_delta) * v_item.unit_cost;
    if new.trx_type = 'PURCHASE' then
        v_dr := acc_id('1301'); v_cr := acc_id('2101');
    elsif new.trx_type = 'SALE' then
        v_dr := acc_id('5101'); v_cr := acc_id('1301');
    elsif v_delta > 0 then
        v_dr := acc_id('1301'); v_cr := acc_id('5102');
    else
        v_dr := acc_id('5102'); v_cr := acc_id('1301');
    end if;

    -- kolom source & created_by ditambahkan di 04_audit_trail.sql (jalankan 01–04 sebelum ada transaksi)
    insert into journal_headers (trx_date, ref_no, description, source, created_by)
    values (new.trx_date::date, 'INV-' || lpad(new.trx_id::text, 6, '0'),
            format('%s %s x %s @ %s (trx #%s)', new.trx_type, abs(v_delta), v_item.item_name, v_item.unit_cost, new.trx_id),
            'INVENTORY', 'sistem:trigger-persediaan')
    returning header_id into v_hdr;

    insert into journal_lines (header_id, account_id, debit, credit, memo) values
        (v_hdr, v_dr, v_amount, 0, new.item_id),
        (v_hdr, v_cr, 0, v_amount, new.item_id);

    update journal_headers set status_posting = 'POSTED', posted_by = 'sistem:trigger-persediaan' where header_id = v_hdr;
    return new;
end $$;

-- AFTER INSERT: baris transaksi sudah lolos CHECK/FK; exception di sini me-rollback semuanya.
create trigger trg_inventory_after_insert
    after insert on inventory_transactions
    for each row execute function trg_update_stock_and_journal();
