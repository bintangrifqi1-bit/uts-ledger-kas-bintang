-- =====================================================================
-- SOAL 2.2 — Race condition: dua kasir menjual item yang sama, stok tinggal 1
-- =====================================================================
--
-- Tanpa penguncian (READ COMMITTED default), kedua sesi bisa membaca stok = 1,
-- keduanya lolos pengecekan, lalu stok menjadi -1 (overselling / phantom stock).
--
-- Teknik A (dipakai di trigger 02): pessimistic row lock "SELECT ... FOR UPDATE"
--
--   Kasir A                                   Kasir B
--   BEGIN;                                    BEGIN;
--   INSERT ... ('BRG-01','SALE',1);
--     -> trigger: SELECT ... FOR UPDATE
--        (baris BRG-01 terkunci)              INSERT ... ('BRG-01','SALE',1);
--     -> stok 1 - 1 = 0                         -> trigger: SELECT ... FOR UPDATE  => MENUNGGU
--   COMMIT;  (lock dilepas)                     -> membaca versi terbaru: stok = 0
--                                               -> RAISE EXCEPTION 'Stok ... tidak cukup'
--                                             ROLLBACK otomatis
--
-- Teknik B (alternatif): isolasi SERIALIZABLE + retry di aplikasi
--
--   BEGIN ISOLATION LEVEL SERIALIZABLE;
--   SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG-01';
--   UPDATE inventory_items SET stock_qty = stock_qty - 1 WHERE item_id = 'BRG-01';
--   COMMIT;   -- salah satu sesi gagal dengan SQLSTATE 40001 (serialization_failure);
--             -- aplikasi wajib mengulang transaksi itu dari awal.
--
-- Teknik C (satu perintah atomik, tanpa membaca dulu):
--
--   UPDATE inventory_items SET stock_qty = stock_qty - 1
--    WHERE item_id = 'BRG-01' AND stock_qty >= 1
--   RETURNING stock_qty;      -- 0 baris kembali = stok habis, tolak penjualan
--
-- Teknik A dipilih karena berada di dalam trigger: berlaku untuk SEMUA jalur input
-- (aplikasi kasir, API, SQL manual) dan tidak memerlukan logika retry di klien.
-- =====================================================================

-- RPC untuk membuktikan Teknik A dari dua koneksi paralel (dipanggil via Supabase REST).
-- p_hold_seconds menahan transaksi tetap terbuka (maks 3 detik) agar tabrakan terlihat.
create or replace function record_inventory_trx(
    p_item_id      text,
    p_trx_type     text,
    p_qty          int,
    p_hold_seconds numeric default 0
) returns json
language plpgsql security definer set search_path = public as $$
declare
    v_trx int;
    v_t0  timestamptz := clock_timestamp();
begin
    insert into inventory_transactions (item_id, trx_type, qty)
    values (p_item_id, p_trx_type, p_qty)
    returning trx_id into v_trx;

    perform pg_sleep(least(greatest(p_hold_seconds, 0), 3));

    return json_build_object(
        'trx_id', v_trx,
        'stock_after', (select stock_qty from inventory_items where item_id = p_item_id),
        'elapsed_ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
end $$;
