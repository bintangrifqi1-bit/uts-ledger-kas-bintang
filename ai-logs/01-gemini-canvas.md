# Log AI 1 — Gemini Canvas (Soal 3.1a)

- **Tanggal**: 13 Oktober 2026
- **Alat**: Gemini (mode Pro) + tool **Canvas**
- **Tujuan**: merancang komponen UI formulir entri jurnal dinamis dengan *live balanced indicator*.

## Prompt instruksi yang digunakan

```text
Peran: kamu front-end engineer untuk sistem informasi akuntansi. Buat satu file HTML
(Tailwind CSS via CDN + JavaScript murni, tanpa framework) berupa formulir Voucher Kas
Keluar / Bukti Kas Keluar (BKK) untuk PT Diponegoro Logistik Utama. Ketentuan:
(1) Header voucher: tanggal transaksi (tidak boleh di masa depan), nama petugas
    (created_by), dibayarkan kepada, dan uraian.
(2) Tabel baris jurnal dinamis: pilih akun, memo, debit, kredit, tombol tambah/hapus
    baris; satu baris hanya boleh berisi debit ATAU kredit. Daftar akun contoh:
    1101 Kas Besar, 1102 Kas Kecil, 1103 Bank Mandiri (ketiganya akun kas),
    2101 Utang Usaha, 6102 Beban Listrik dan Air, 6103 Beban Pengiriman,
    6104 Beban Perlengkapan Kantor, 6105 Beban Pemeliharaan Armada.
(3) Live balanced indicator: total debit dan total kredit dihitung otomatis setiap input
    berubah; tampilkan status SEIMBANG (hijau) atau BELUM SEIMBANG beserta selisihnya
    (kuning). Hitung dalam satuan sen (integer) agar bebas galat floating point.
(4) Checklist aturan bisnis yang ikut berubah secara live: minimal 2 baris lengkap; ada
    akun kas di sisi kredit; akun kas tidak boleh didebit (karena ini kas keluar);
    total debit = total kredit.
(5) Tombol Submit nonaktif sampai semua aturan terpenuhi (asas zero-discrepancy). Saat
    submit, tampilkan payload JSON {trx_date, prepared_by, counterparty, description,
    lines:[{account_code, debit, credit, memo}]} yang nantinya dikirim ke Supabase RPC
    bernama post_cash_voucher.
(6) Format angka Rupiah locale id-ID, tampilan bersih, dan aksesibel (label pada setiap
    input).
```

## Teknik prompt

| Teknik | Penerapan |
|---|---|
| Role prompting | "kamu front-end engineer untuk sistem informasi akuntansi" |
| Batasan teknologi | satu file HTML, Tailwind CDN, JS murni, supaya mudah di-host di GitHub Pages |
| Aturan bisnis eksplisit dan bernomor | zero-discrepancy, sisi kredit kas, larangan debit kas |
| Kontrak data | bentuk payload JSON disamakan dengan parameter RPC `post_cash_voucher` di database |
| Aspek non-fungsional | perhitungan dalam sen (anti galat floating point), locale id-ID, aksesibilitas |

## Hasil dan integrasi

**Catatan proses:** pada percobaan pertama Gemini menjawab "Saya hanya AI berbasis teks dan tidak bisa membantu Anda untuk itu", dan regenerate memberi jawaban yang sama. Setelah diberi prompt lanjutan berikut, Canvas berhasil dibuat:

```text
Ini untuk tugas kuliah Sistem Informasi Akuntansi. Tolong tuliskan kodenya di Canvas sebagai
satu file HTML yang bisa langsung di-preview, sesuai semua ketentuan di atas.
```

**Output Canvas** ("Bukti Kas Keluar - PT Diponegoro Logistik Utama", ±34 KB HTML) berisi fungsi `formatRupiah`, `setMaxDateToday`, `addJournalRow`, `removeJournalRow`, `handleAmountInput` (debit/kredit saling eksklusif), `analyzeAndValidate` (menghitung total dalam sen), `updateBalanceUI`, `updateChecklistUI`, `toggleSubmitButton`, dan modal payload JSON. Screenshot: `docs/img/04-gemini-canvas.png`.

Inti logika hasil Gemini (dikutip dari Canvas):

```js
const debitCents = Math.round(debitVal * 100);
const creditCents = Math.round(creditVal * 100);
totalDebitCents += debitCents;
totalCreditCents += creditCents;
if (accCode) {
    if (debitCents > 0 || creditCents > 0) validRowsCount++;
    const accountRef = chartOfAccounts.find(a => a.code === accCode);
    if (accountRef && accountRef.is_cash) {
        if (creditCents > 0) ruleHasCashCredit = true;
        if (debitCents > 0) ruleNoCashDebit = false;
    }
}
const ruleMinRows = validRowsCount >= 2;
const ruleIsBalanced = (totalDebitCents === totalCreditCents) && (totalDebitCents > 0);
```

**Hasil review kode Gemini:**
- ✅ Perhitungan dalam sen, debit/kredit saling eksklusif, dan checklist aturan sesuai permintaan.
- ⚠️ **Celah:** nominal pada baris yang **belum memilih akun** tetap ikut dijumlahkan ke total. Akibatnya voucher bisa berstatus "seimbang" dan lolos submit dengan baris tanpa akun. Di `index.html` final, setiap baris wajib punya akun dan tepat satu nominal > 0 sebelum Submit aktif. Database juga menolak akun yang tidak terdaftar.
- ⚠️ Daftar akun di-*hardcode* dan belum ada cek saldo kas. Keduanya ditambahkan pada versi final (COA dibaca dari Supabase, aturan "pengeluaran ≤ saldo kas").

## Pembagian peran AI dan manusia

Gemini dipakai sebagai **perancang purwarupa UI**. Keputusan berikut tetap diambil dan diverifikasi sendiri:
1. Validasi di frontend hanya untuk kenyamanan pengguna. Aturan yang sama ditegakkan ulang di database (RPC `post_cash_voucher`, constraint trigger seimbang, CHECK, RLS). Ini menjawab konteks Soal 1: validasi frontend saja bisa dilewati lewat API.
2. Daftar akun pada versi final dibaca langsung dari tabel `chart_of_accounts`, tidak di-*hardcode*.
3. Ditambahkan panel saldo kas, aturan "pengeluaran ≤ saldo kas", daftar jurnal POSTED, tombol verifikasi hash, storno, dan audit log.
