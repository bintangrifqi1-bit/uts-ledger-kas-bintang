-- =====================================================================
-- Data demo: saldo awal, barang gudang, mutasi persediaan, voucher kas keluar
-- Jalankan setelah 01–04.
-- =====================================================================

insert into inventory_items (item_id, item_name, stock_qty, unit_cost) values
    ('BRG-01', 'Palet Kayu 120x100 cm',      40, 185000),
    ('BRG-02', 'Stretch Film 50 cm',        120,  95000),
    ('BRG-03', 'Kardus Double Wall 60x40',  500,   7500),
    ('BRG-04', 'Lakban Coklat 2 inci',      300,  12500),
    ('BRG-05', 'Timbangan Lantai Digital',    1, 2350000);   -- stok 1: dipakai uji race condition

-- Saldo awal 1 Oktober 2026 (persediaan = nilai stok di atas = 28.650.000)
do $$
declare v bigint;
begin
    insert into journal_headers (trx_date, ref_no, description, created_by)
    values ('2026-10-01', 'SA-202610', 'Saldo awal periode Oktober 2026', 'Bintang Rifqi Maulana DS')
    returning header_id into v;
    insert into journal_lines (header_id, account_id, debit, credit) values
        (v, acc_id('1101'),  25000000, 0),
        (v, acc_id('1102'),   3000000, 0),
        (v, acc_id('1103'), 180000000, 0),
        (v, acc_id('1301'),  28650000, 0),
        (v, acc_id('1501'),  45000000, 0),
        (v, acc_id('3101'), 0, 281650000);
    update journal_headers set status_posting = 'POSTED', posted_by = 'Bintang Rifqi Maulana DS' where header_id = v;
end $$;

-- Mutasi persediaan (trigger membuat jurnal INV-xxxxxx otomatis)
insert into inventory_transactions (item_id, trx_type, qty, trx_date) values
    ('BRG-02', 'PURCHASE',   30, '2026-10-13 08:15'),
    ('BRG-01', 'SALE',       12, '2026-10-13 09:40'),
    ('BRG-03', 'SALE',      150, '2026-10-13 10:05'),
    ('BRG-04', 'ADJUSTMENT', -4, '2026-10-13 11:30');   -- 4 rol rusak saat stock opname

-- Voucher kas keluar lewat RPC (jalur yang sama dengan form web)
select post_cash_voucher('{
  "trx_date": "2026-10-13", "prepared_by": "Bintang Rifqi Maulana DS",
  "counterparty": "PT PLN (Persero) & Perumda Air Minum Tirta Moedal",
  "description": "Pembayaran listrik dan air gudang Kaligawe periode September 2026",
  "lines": [ {"account_code": "6102", "debit": 2450000, "credit": 0, "memo": "Tagihan PLN + PDAM"},
             {"account_code": "1103", "debit": 0, "credit": 2450000, "memo": "Transfer giro Mandiri"} ] }');

select post_cash_voucher('{
  "trx_date": "2026-10-13", "prepared_by": "Bintang Rifqi Maulana DS",
  "counterparty": "CV Plastindo Jaya",
  "description": "Pelunasan faktur pembelian stretch film No. PJ-0921",
  "lines": [ {"account_code": "2101", "debit": 2850000, "credit": 0, "memo": "Faktur PJ-0921"},
             {"account_code": "1103", "debit": 0, "credit": 2850000, "memo": "Transfer giro Mandiri"} ] }');

select post_cash_voucher('{
  "trx_date": "2026-10-13", "prepared_by": "Bintang Rifqi Maulana DS",
  "counterparty": "Sopir armada B 9421 KXT",
  "description": "BBM, tol, dan ATK pengiriman Semarang - Kudus",
  "lines": [ {"account_code": "6103", "debit": 675000, "credit": 0, "memo": "BBM + tol"},
             {"account_code": "6104", "debit": 125000, "credit": 0, "memo": "Map & label pengiriman"},
             {"account_code": "1102", "debit": 0, "credit": 800000, "memo": "Kas kecil gudang"} ] }');
