# Log AI 2 — NotebookLM: verifikasi kepatuhan PSAK (Soal 3.1b)

- **Tanggal**: 13 Oktober 2026
- **Alat**: NotebookLM (Gemini Notebook), notebook "Accounting Principles of Cash and Receivables Management", 11 sumber
- **Sumber yang dimasukkan**
  1. 10 sumber web hasil *Fast Research* dengan kueri: `PSAK 2 Laporan Arus Kas definisi kas dan setara kas IAI, pengakuan pengeluaran kas, bukti kas keluar pengendalian internal`. Termasuk: *PSAK 2 (Penyesuaian 2014): Laporan Arus Kas — Accounting BINUS*, *Analisis Penerapan Laporan Arus Kas berdasarkan PSAK No. 2*, *Bukti Kas Keluar: Fungsi, Tujuan, Jenis — Accurate*, *Akuntansi Pengeluaran Kas — e-Jurnal STEBIS Al-Ulum*, *Analisis Sistem Pengendalian Internal atas Prosedur Pengeluaran Kas*, *Memperkuat Pengendalian Internal atas Transaksi Kas Kecil*, dan lainnya.
  2. Dokumen kode yang diuji: [`notebooklm-sumber-kode.md`](notebooklm-sumber-kode.md) (aturan bisnis + potongan SQL `post_cash_voucher`).

## Prompt

```text
Bertindaklah sebagai auditor internal. Berdasarkan sumber PSAK 2 dan literatur pengendalian
internal pengeluaran kas di notebook ini, verifikasi apakah 10 aturan bisnis dan kode SQL pada
sumber 'Sumber NotebookLM: logika voucher kas keluar' sudah patuh terhadap: (a) definisi kas dan
setara kas (apakah klasifikasi akun 1101, 1102, 1103 sebagai kas tepat; bagaimana perlakuan
deposito berjangka lebih dari 3 bulan dan cerukan bank), (b) pengakuan pengeluaran kas dan asas
berpasangan debit-kredit, (c) pengendalian internal bukti kas keluar (otorisasi, nomor urut
tercetak, pemisahan tugas, jejak audit). Untuk setiap aturan beri status SESUAI atau PERLU
PERBAIKAN dengan alasan singkat dan sitasi sumber, lalu tuliskan rekomendasi perbaikan dalam
bahasa Indonesia.
```

## Ringkasan jawaban NotebookLM

**(a) Kas dan setara kas.** Akun 1101 Kas Besar dan 1102 Kas Kecil (*cash on hand*) serta 1103 Bank Giro (*demand deposits*) **tepat** diklasifikasikan sebagai kas menurut PSAK 2. Deposito berjangka hanya menjadi setara kas bila jatuh tempo ≤ 3 bulan sejak perolehan (PSAK 2 par. 6). Deposito > 3 bulan adalah investasi, jadi `is_cash = false`. Cerukan bank yang dapat ditarik sewaktu-waktu dan menjadi bagian pengelolaan kas dihitung sebagai pengurang kas. Bila berupa pinjaman berjangka, cerukan diklasifikasikan sebagai liabilitas.

**(b) Pengakuan dan asas berpasangan.** Pengeluaran kas sudah diakui dengan mengkredit kas/bank dan mendebit akun lawan, dengan total debit = kredit (zero-discrepancy).

**(c) Pengendalian internal.** Penomoran otomatis BKK-YYYYMM-#### memenuhi prinsip *pre-numbered documents*. Imutabilitas POSTED, storno, created_at/posted_at, dan hash SHA-256 dinilai "jejak audit digital yang sangat baik". Yang belum ada: **otorisasi/approval berjenjang** dan **pemisahan tugas** (sistem belum mencegah created_by = posted_by).

| No | Aturan | Status NotebookLM |
|---|---|---|
| 1 | Tanggal tidak boleh di masa depan | SESUAI |
| 2 | Petugas, uraian, penerima wajib | PERLU PERBAIKAN (belum ada approver terpisah) |
| 3 | Min. 2 baris, satu sisi, ≥ 0, maks 2 desimal | SESUAI |
| 4 | Akun kas tidak boleh didebit | PERLU PERBAIKAN (menghalangi transfer internal, mis. pengisian kas kecil dari bank) |
| 5 | Minimal satu akun kas dikredit | SESUAI |
| 6 | Total debit = total kredit | SESUAI |
| 7 | Pengeluaran ≤ saldo kas | PERLU PERBAIKAN untuk bank yang punya fasilitas cerukan resmi |
| 8 | Nomor bukti berurutan | SESUAI |
| 9 | POSTED tidak bisa UPDATE/DELETE, koreksi via storno | SESUAI |
| 10 | created_by, created_at, posted_by, posted_at, hash berantai | PERLU PERBAIKAN (belum menolak created_by = posted_by) |

## Tindak lanjut (keputusan penyusun)

| Temuan | Tanggapan |
|---|---|
| Aturan 4: transfer antar-kas | **Dipertahankan sebagai desain.** Pengisian kas kecil dari bank bukan pengeluaran kas entitas (saldo kas & setara kas total tidak berubah, PSAK 2 juga tidak memperlakukannya sebagai arus kas). Transaksi ini dicatat dengan bukti pemindahbukuan terpisah, bukan BKK. Dengan begitu, BKK hanya berisi pengeluaran kas yang sebenarnya. |
| Aturan 7: cerukan bank | **Dipertahankan.** PT Diponegoro Logistik Utama (kasus) tidak memiliki fasilitas cerukan, sehingga batas = saldo. Jika kelak ada, cukup tambah kolom `overdraft_limit` di `chart_of_accounts` dan ganti pembanding menjadi `saldo + overdraft_limit`. |
| Aturan 2 & 10: pemisahan tugas | **Diakui sebagai keterbatasan purwarupa.** Demo berjalan tanpa login, sehingga nama petugas masih diisi sendiri. Pada sistem produksi: Supabase Auth, `created_by = auth.uid()`, status `APPROVED` di antara DRAFT dan POSTED, serta aturan `approved_by <> created_by`. |
| Deposito > 3 bulan | Sesuai rancangan: akun investasi tidak diberi `is_cash = true`. |
