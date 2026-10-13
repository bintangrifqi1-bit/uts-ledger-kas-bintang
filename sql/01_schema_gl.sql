-- =====================================================================
-- SOAL 1 — General Ledger: Chart of Accounts, Journal Header, Journal Line
-- Entitas: ritel modern (modul GL mandiri). PostgreSQL 15+ / Supabase.
-- =====================================================================

-- 1.2  Master akun. Tidak ada kolom turunan (mis. "kelompok" yang menentukan
--      klasifikasi laporan) agar tidak ada ketergantungan transitif (3NF).
create table chart_of_accounts (
    account_id      smallint generated always as identity primary key,
    account_code    varchar(10)  not null unique,
    account_name    varchar(100) not null,
    normal_balance  char(1)      not null check (normal_balance in ('D', 'K')),   -- D = Debit, K = Kredit
    report_class    varchar(10)  not null check (report_class in ('NERACA', 'LABA_RUGI')),
    is_cash         boolean      not null default false   -- kas & setara kas (PSAK 2), dipakai validasi voucher kas keluar
);

-- 1.2  Header = satu dokumen sumber / bukti transaksi.
create table journal_headers (
    header_id       bigint generated always as identity primary key,
    trx_date        date         not null,
    ref_no          varchar(30)  not null unique,              -- nomor bukti, tidak boleh ganda
    description     text         not null,
    status_posting  varchar(10)  not null default 'DRAFT'
                    check (status_posting in ('DRAFT', 'POSTED'))
);

-- 1.2  Line = baris debit/kredit milik satu header.
create table journal_lines (
    line_id     bigint generated always as identity primary key,
    header_id   bigint   not null references journal_headers (header_id)   on delete restrict,
    account_id  smallint not null references chart_of_accounts (account_id) on delete restrict,
    debit       numeric(18, 2) not null default 0,
    credit      numeric(18, 2) not null default 0,
    memo        varchar(200),
    constraint ck_debit_non_negative  check (debit  >= 0),
    constraint ck_credit_non_negative check (credit >= 0),
    constraint ck_not_both_zero       check (debit > 0 or credit > 0),   -- baris nol-nol ditolak
    constraint ck_single_side         check (debit = 0 or credit = 0)    -- satu baris hanya satu sisi
);
create index ix_lines_header  on journal_lines (header_id);
create index ix_lines_account on journal_lines (account_id);

-- ---------------------------------------------------------------------
-- Penegakan asas berpasangan DI DATABASE (bukan di frontend).
-- Constraint trigger DEFERRABLE INITIALLY DEFERRED: dicek saat COMMIT,
-- sehingga header + semua line boleh di-insert dulu dalam satu transaksi,
-- tetapi transaksi yang tidak seimbang / kurang dari 2 baris pasti di-rollback,
-- termasuk yang dikirim langsung lewat API.
-- ---------------------------------------------------------------------
create or replace function fn_assert_journal_balanced() returns trigger
language plpgsql as $$
declare
    v_ids bigint[];
    v_id  bigint;
    v_dr  numeric;
    v_cr  numeric;
    v_n   int;
begin
    if tg_table_name = 'journal_headers' then
        v_ids := array[new.header_id];
    elsif tg_op = 'INSERT' then
        v_ids := array[new.header_id];
    elsif tg_op = 'DELETE' then
        v_ids := array[old.header_id];
    else
        v_ids := array[old.header_id, new.header_id];
    end if;

    foreach v_id in array v_ids loop
        continue when not exists (select 1 from journal_headers where header_id = v_id);
        select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*)
          into v_dr, v_cr, v_n
          from journal_lines where header_id = v_id;
        if v_n < 2 or v_dr <> v_cr then
            raise exception 'Jurnal #% ditolak: tidak seimbang (debit %, kredit %, % baris)', v_id, v_dr, v_cr, v_n
                using errcode = '23514', hint = 'Total debit harus sama dengan total kredit, minimal 2 baris.';
        end if;
    end loop;
    return null;
end $$;

create constraint trigger ctrg_lines_balanced
    after insert or update or delete on journal_lines
    deferrable initially deferred
    for each row execute function fn_assert_journal_balanced();

create constraint trigger ctrg_header_has_lines
    after insert on journal_headers
    deferrable initially deferred
    for each row execute function fn_assert_journal_balanced();

-- Helper: kode akun -> id (dipakai trigger persediaan & RPC voucher)
create or replace function acc_id(p_code text) returns smallint
language sql stable as $$
    select account_id from chart_of_accounts where account_code = p_code
$$;

-- ---------------------------------------------------------------------
-- Data master akun
-- ---------------------------------------------------------------------
insert into chart_of_accounts (account_code, account_name, normal_balance, report_class, is_cash) values
    ('1101', 'Kas Besar',                    'D', 'NERACA',    true),
    ('1102', 'Kas Kecil',                    'D', 'NERACA',    true),
    ('1103', 'Bank Mandiri - Giro',          'D', 'NERACA',    true),
    ('1201', 'Piutang Usaha',                'D', 'NERACA',    false),
    ('1301', 'Persediaan Barang Dagang',     'D', 'NERACA',    false),
    ('1401', 'Sewa Dibayar di Muka',         'D', 'NERACA',    false),
    ('1501', 'Peralatan Gudang',             'D', 'NERACA',    false),
    ('2101', 'Utang Usaha',                  'K', 'NERACA',    false),
    ('2102', 'Utang Gaji',                   'K', 'NERACA',    false),
    ('3101', 'Modal Pemilik',                'K', 'NERACA',    false),
    ('4101', 'Penjualan',                    'K', 'LABA_RUGI', false),
    ('5101', 'Beban Pokok Pendapatan (HPP)', 'D', 'LABA_RUGI', false),
    ('5102', 'Selisih Persediaan',           'D', 'LABA_RUGI', false),
    ('6101', 'Beban Gaji',                   'D', 'LABA_RUGI', false),
    ('6102', 'Beban Listrik dan Air',        'D', 'LABA_RUGI', false),
    ('6103', 'Beban Pengiriman',             'D', 'LABA_RUGI', false),
    ('6104', 'Beban Perlengkapan Kantor',    'D', 'LABA_RUGI', false),
    ('6105', 'Beban Pemeliharaan Armada',    'D', 'LABA_RUGI', false);
