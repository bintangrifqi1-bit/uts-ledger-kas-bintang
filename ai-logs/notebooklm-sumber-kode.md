# Sumber NotebookLM: logika voucher kas keluar (PT Diponegoro Logistik Utama)

Dokumen ini di-upload ke NotebookLM sebagai sumber "kode yang diuji", bersama referensi standar akuntansi.

## 1. Daftar akun kas & setara kas (chart_of_accounts.is_cash = true)
- 1101 Kas Besar (kas di tangan)
- 1102 Kas Kecil (kas di tangan, dana kas kecil)
- 1103 Bank Mandiri - Giro (simpanan giro, dapat ditarik sewaktu-waktu)
Akun bukan kas, contoh: 1201 Piutang Usaha, 1301 Persediaan, 1401 Sewa Dibayar di Muka, 2101 Utang Usaha.

## 2. Aturan bisnis yang ditegakkan fungsi database post_cash_voucher (Supabase RPC)
1. Tanggal voucher wajib diisi dan tidak boleh di masa depan (`v_date > current_date` ditolak).
2. Petugas (created_by), uraian, dan penerima pembayaran wajib diisi.
3. Minimal 2 baris jurnal; setiap baris hanya satu sisi (CHECK debit = 0 OR credit = 0), nominal ≥ 0, tidak boleh nol-nol, maksimal 2 desimal.
4. Akun kas TIDAK boleh didebit dalam voucher kas keluar (penerimaan kas memakai bukti kas masuk).
5. Minimal satu akun kas/bank harus dikredit.
6. Total debit harus sama dengan total kredit (zero-discrepancy). Diperiksa lagi saat COMMIT oleh constraint trigger `fn_assert_journal_balanced`.
7. Pengeluaran per akun kas tidak boleh melebihi saldo akun kas itu menurut jurnal berstatus POSTED (saldo kas tidak boleh negatif).
8. Nomor bukti otomatis berurutan per bulan: BKK-YYYYMM-0001.
9. Setelah POSTED, jurnal tidak bisa di-UPDATE atau di-DELETE. Koreksi hanya lewat jurnal pembalik (storno) yang menukar debit dan kredit.
10. Setiap jurnal POSTED menyimpan created_by, created_at (waktu server), posted_by, posted_at, dan hash_checksum SHA-256 berantai.

## 3. Potongan kode SQL (inti validasi)

```sql
for v_line in select * from jsonb_array_elements(p_voucher -> 'lines') loop
    select * into v_acc from chart_of_accounts where account_code = v_line ->> 'account_code';
    if not found then raise exception 'Akun % tidak terdaftar', v_line ->> 'account_code'; end if;
    v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
    v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
    if v_acc.is_cash and v_dr > 0 then
        raise exception 'Voucher kas keluar tidak boleh mendebit akun kas (%).', v_acc.account_name;
    end if;
    v_tot_dr := v_tot_dr + v_dr;  v_tot_cr := v_tot_cr + v_cr;
    if v_acc.is_cash then v_cash_cr := v_cash_cr + v_cr; end if;
end loop;
if v_cash_cr = 0 then raise exception 'Voucher kas keluar wajib mengkredit minimal satu akun kas/bank'; end if;
if v_tot_dr <> v_tot_cr then raise exception 'Zero-discrepancy gagal: debit % <> kredit %', v_tot_dr, v_tot_cr; end if;
-- saldo kas tidak boleh minus
if r.keluar > (select coalesce(sum(l.debit - l.credit), 0) from journal_lines l
                 join journal_headers h using (header_id)
                where l.account_id = r.account_id and h.status_posting = 'POSTED') then
    raise exception 'Saldo % tidak mencukupi untuk pengeluaran %', r.account_name, r.keluar;
end if;
```

## 4. Contoh transaksi yang sudah diposting
| No. bukti | Uraian | Jurnal |
|---|---|---|
| BKK-202610-0001 | Bayar listrik & air gudang | Dr 6102 Beban Listrik dan Air 2.450.000 / Cr 1103 Bank 2.450.000 |
| BKK-202610-0002 | Pelunasan utang ke CV Plastindo Jaya | Dr 2101 Utang Usaha 2.850.000 / Cr 1103 Bank 2.850.000 |
| BKK-202610-0003 | BBM, tol, ATK pengiriman | Dr 6103 675.000, Dr 6104 125.000 / Cr 1102 Kas Kecil 800.000 |
| BKK-202610-0004 | Servis armada | Dr 6105 1.250.000, Dr 6104 35.000 / Cr 1101 Kas Besar 1.285.000 |
| BKK-202610-0005 → STR-BKK-202610-0005 | ATK salah dicatat ke Beban Gaji, lalu distorno | jurnal pembalik menukar debit/kredit |
