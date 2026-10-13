# Hasil `select * from run_ledger_tests();` — Supabase, 13 Oktober 2026

Setiap uji berjalan dalam sub-transaksi yang di-rollback, sehingga data asli tidak berubah.

| Uji | Hasil | Detail (pesan dari database) |
|---|---|---|
| T01 Jurnal tidak seimbang ditolak (dikirim langsung, tanpa frontend) | PASS | Jurnal #17 ditolak: tidak seimbang (debit 100000.00, kredit 90000.00, 2 baris) |
| T02 Baris debit = 0 dan kredit = 0 ditolak | PASS | violates check constraint "ck_not_both_zero" |
| T03 Nominal debit negatif ditolak | PASS | violates check constraint "ck_debit_non_negative" |
| T04 Hapus akun yang sudah dipakai jurnal ditolak (ON DELETE RESTRICT) | PASS | violates foreign key constraint "journal_lines_account_id_fkey" |
| T05 PURCHASE menambah stok dan menjurnal Dr Persediaan / Cr Utang Usaha | PASS | stok 296 -> 306, Dr Persediaan 125000.00 |
| T06 SALE melebihi stok ditolak (anti-negative inventory) | PASS | Stok BRG-01 (Palet Kayu 120x100 cm) tidak cukup: tersedia 28, keluar 29 |
| T07 SALE mengurangi stok dan menjurnal Dr HPP / Cr Persediaan | PASS | stok 28 -> 26, Dr HPP 370000.00 |
| T08 UPDATE jurnal POSTED ditolak | PASS | Jurnal SA-202610 sudah POSTED: UPDATE ditolak. Koreksi wajib melalui jurnal pembalik (storno). |
| T09 DELETE jurnal POSTED ditolak | PASS | Jurnal SA-202610 sudah POSTED: DELETE ditolak. Koreksi wajib melalui jurnal pembalik (storno). |
| T10 Ubah nominal baris jurnal POSTED ditolak | PASS | Baris jurnal milik jurnal POSTED tidak dapat di-UPDATE |
| T11 Voucher kas keluar tidak seimbang ditolak oleh RPC | PASS | Zero-discrepancy gagal: debit 50000 <> kredit 40000 |
| T12 Voucher tanpa kredit akun kas ditolak | PASS | Voucher kas keluar wajib mengkredit minimal satu akun kas/bank |
| T13 Voucher melebihi saldo kas ditolak | PASS | Saldo Kas Kecil tidak mencukupi untuk pengeluaran 99000000 |
| T14 Voucher valid: POSTED, created_by terisi, hash valid | PASS | BKK-202610-0004 hash fba962cf1f52e224… |
| T15 Storno membalik saldo kas; storno kedua ditolak | PASS | saldo Kas Kecil kembali ke 2200000.00; storno ganda ditolak |
| T16 Manipulasi langsung (trigger dimatikan DBA) terdeteksi oleh hash_checksum | PASS | hash_valid = false setelah deskripsi diubah |

**16/16 PASS**
