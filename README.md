# UTS Pengkodean dan Pemrograman

**Bintang Rifqi Maulana DS** · NIM 12030123140235 · S1 Akuntansi FEB Universitas Diponegoro · Kelas E · 13 Oktober 2026
Dosen pengampu: Totok Dewayanto

- 🌐 **Demo web (GitHub Pages):** https://bintangrifqi1-bit.github.io/uts-ledger-kas-bintang/
- 🗄️ **Database:** Supabase (PostgreSQL), project `uts-ledger-kas`, region Asia-Pacific

## Isi repositori

| Path | Isi | Soal |
|---|---|---|
| [`sql/01_schema_gl.sql`](sql/01_schema_gl.sql) | DDL `chart_of_accounts`, `journal_headers`, `journal_lines` (PK, FK `ON DELETE RESTRICT`, CHECK) + constraint trigger debit = kredit | 1.1, 1.2 |
| [`sql/02_inventory_trigger.sql`](sql/02_inventory_trigger.sql) | `trg_update_stock_and_journal()`: mutasi stok, anti stok negatif, jurnal Persediaan/HPP otomatis | 2.1 |
| [`sql/03_concurrency.sql`](sql/03_concurrency.sql) | `SELECT … FOR UPDATE`, alternatif SERIALIZABLE & update atomik, RPC uji paralel | 2.2 |
| [`sql/04_audit_trail.sql`](sql/04_audit_trail.sql) | Kunci POSTED, storno, `created_by/created_at/hash_checksum` berantai, audit log, RLS, RPC voucher | 3.2 |
| [`sql/05_seed_demo.sql`](sql/05_seed_demo.sql) | Saldo awal, barang gudang, mutasi persediaan, voucher contoh | — |
| [`sql/06_tests.sql`](sql/06_tests.sql) | `run_ledger_tests()`: 16 uji otomatis (semua di-rollback) | 1–3 |
| [`index.html`](index.html) | Purwarupa web Voucher Kas Keluar (Tailwind + supabase-js) | 3.1a |
| [`docs/erd.md`](docs/erd.md) | ERD (Mermaid) | 1.1 |
| [`docs/hasil-uji-sql.md`](docs/hasil-uji-sql.md), [`docs/hasil-uji-api.json`](docs/hasil-uji-api.json) | Bukti uji: 16/16 PASS, bypass API, race condition, storno | 1–3 |
| [`ai-logs/`](ai-logs) | Prompt & hasil **Gemini Canvas** dan **NotebookLM** | 3.1 |
| [`docs/laporan.pdf`](docs/laporan.pdf) | Laporan jawaban UTS | semua |

## Menjalankan ulang

1. Buat project Supabase, lalu jalankan `sql/01` sampai `sql/06` berurutan di SQL Editor.
2. `select * from run_ledger_tests();` harus menampilkan 16 baris PASS.
3. Ganti `SUPABASE_URL` dan `SUPABASE_ANON_KEY` di `index.html` dengan milik project, lalu buka file tersebut di browser atau host di GitHub Pages.

> Anon key di `index.html` memang publik. Keamanan data dijaga oleh RLS (klien hanya boleh `SELECT`). Semua penulisan wajib lewat fungsi RPC yang memvalidasi ulang di server.

## Arsitektur singkat

```
Browser (index.html) ──supabase-js──► PostgREST ──► RPC post_cash_voucher / reverse_journal / verify_journal
        │ validasi live (UX)                         │ validasi ulang (trust boundary)
        └── SELECT saja (RLS) ◄──────────────────────┴─► trigger: seimbang saat COMMIT, kunci POSTED,
                                                          hash SHA-256 berantai, audit_log append-only
inventory_transactions ──AFTER INSERT──► trg_update_stock_and_journal(): FOR UPDATE → stok → jurnal HPP
```
