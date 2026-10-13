-- =====================================================================
-- SOAL 3.2 — Audit trail & immutability (Supabase RPC + trigger PostgreSQL)
--   * created_by / created_at diisi server dan tidak bisa ditimpa
--   * POSTED = terkunci: UPDATE/DELETE header maupun line ditolak oleh trigger
--   * koreksi hanya lewat jurnal pembalik (storno) -> reverse_journal()
--   * hash_checksum SHA-256 berantai: hash jurnal ini memuat hash jurnal POSTED
--     sebelumnya, sehingga mengubah satu jurnal lama memutus rantai sesudahnya
-- =====================================================================

alter table journal_headers
    add column source        varchar(20) not null default 'MANUAL'
                             check (source in ('MANUAL', 'INVENTORY', 'VOUCHER_KK', 'STORNO')),
    add column counterparty  varchar(100),                               -- dibayarkan kepada
    add column reversal_of   bigint unique references journal_headers (header_id) on delete restrict,
    add column created_by    varchar(100) not null default current_user,
    add column created_at    timestamptz  not null default now(),
    add column posted_by     varchar(100),
    add column posted_at     timestamptz,
    add column posted_seq    bigint unique,                              -- urutan rantai hash
    add column prev_hash     char(64),
    add column hash_checksum char(64);

create table audit_log (
    log_id     bigint generated always as identity primary key,
    table_name text        not null,
    record_id  bigint      not null,
    action     text        not null,       -- CREATE | POST | REVERSE
    actor      text        not null,
    logged_at  timestamptz not null default now(),
    detail     jsonb
);

-- ---------------------------------------------------------------------
-- Hash: representasi kanonik header (dari record) + baris jurnal + hash sebelumnya
-- ---------------------------------------------------------------------
create or replace function journal_hash(h journal_headers) returns char(64)
language sql stable as $$
    select encode(sha256(convert_to(concat_ws('|',
        h.header_id, h.trx_date, h.ref_no, h.description, coalesce(h.counterparty, ''),
        h.source, coalesce(h.reversal_of::text, ''), h.created_by,
        to_char(h.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
        h.posted_by, h.posted_seq,
        (select string_agg(concat_ws(':', a.account_code, l.debit, l.credit), ';' order by l.line_id)
           from journal_lines l join chart_of_accounts a using (account_id)
          where l.header_id = h.header_id),
        coalesce(h.prev_hash, 'GENESIS')), 'UTF8')), 'hex')
$$;

-- ---------------------------------------------------------------------
-- Guard header: kunci POSTED, isi kolom audit, hitung hash saat posting
-- ---------------------------------------------------------------------
create or replace function fn_journal_header_guard() returns trigger
language plpgsql as $$
begin
    if tg_op = 'INSERT' then
        if new.status_posting <> 'DRAFT' then
            raise exception 'Jurnal baru harus DRAFT; posting dilakukan setelah semua baris masuk';
        end if;
        new.created_at := now();                       -- waktu server, bukan waktu klien
        new.posted_by := null; new.posted_at := null; new.posted_seq := null;
        new.prev_hash := null; new.hash_checksum := null;
        return new;
    end if;

    if old.status_posting = 'POSTED' then
        raise exception 'Jurnal % sudah POSTED: % ditolak. Koreksi wajib melalui jurnal pembalik (storno).',
            old.ref_no, tg_op using errcode = '42501';
    end if;
    if tg_op = 'DELETE' then
        return old;                                    -- DRAFT boleh dihapus
    end if;

    new.created_by := old.created_by;                  -- identitas & waktu pembuat tidak bisa ditimpa
    new.created_at := old.created_at;

    if new.status_posting = 'POSTED' then              -- transisi DRAFT -> POSTED
        perform pg_advisory_xact_lock(hashtext('gl_posting_chain'));   -- posting serial, rantai tidak bercabang
        select coalesce(max(posted_seq), 0) + 1 into new.posted_seq from journal_headers;
        select hash_checksum into new.prev_hash from journal_headers where posted_seq = new.posted_seq - 1;
        new.posted_by := coalesce(new.posted_by, current_user);
        new.posted_at := now();
        new.hash_checksum := journal_hash(new);
    end if;
    return new;
end $$;

create trigger trg_journal_header_guard
    before insert or update or delete on journal_headers
    for each row execute function fn_journal_header_guard();

-- Guard baris: line milik jurnal POSTED tidak bisa ditambah/diubah/dihapus
create or replace function fn_journal_line_guard() returns trigger
language plpgsql as $$
begin
    if exists (select 1 from journal_headers
                where header_id in (old.header_id, new.header_id) and status_posting = 'POSTED') then
        raise exception 'Baris jurnal milik jurnal POSTED tidak dapat di-%', tg_op using errcode = '42501';
    end if;
    return coalesce(new, old);
end $$;

create trigger trg_journal_line_guard
    before insert or update or delete on journal_lines
    for each row execute function fn_journal_line_guard();

-- Audit log (CREATE, POST, REVERSE)
create or replace function fn_journal_audit() returns trigger
language plpgsql as $$
begin
    if tg_op = 'INSERT' then
        insert into audit_log (table_name, record_id, action, actor, detail)
        values ('journal_headers', new.header_id, 'CREATE', new.created_by,
                jsonb_build_object('ref_no', new.ref_no, 'source', new.source));
    elsif old.status_posting = 'DRAFT' and new.status_posting = 'POSTED' then
        insert into audit_log (table_name, record_id, action, actor, detail)
        values ('journal_headers', new.header_id,
                case when new.reversal_of is null then 'POST' else 'REVERSE' end, new.posted_by,
                jsonb_build_object('ref_no', new.ref_no, 'posted_seq', new.posted_seq,
                                   'hash', new.hash_checksum, 'reversal_of', new.reversal_of));
    end if;
    return null;
end $$;

create trigger trg_journal_audit
    after insert or update on journal_headers
    for each row execute function fn_journal_audit();

-- Audit log sendiri append-only
create or replace function fn_audit_log_append_only() returns trigger
language plpgsql as $$
begin
    raise exception 'audit_log bersifat append-only' using errcode = '42501';
end $$;

create trigger trg_audit_log_append_only
    before update or delete on audit_log
    for each row execute function fn_audit_log_append_only();

-- ---------------------------------------------------------------------
-- RPC 1: simpan + posting voucher kas keluar (Bukti Kas Keluar / BKK)
-- p_voucher = {"trx_date":"2026-10-13","description":"...","counterparty":"...",
--              "prepared_by":"...","lines":[{"account_code":"6102","debit":100000,"credit":0,"memo":"..."}, ...]}
-- ---------------------------------------------------------------------
create or replace function post_cash_voucher(p_voucher jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
    v_date    date := (p_voucher ->> 'trx_date')::date;
    v_by      text := nullif(btrim(p_voucher ->> 'prepared_by'), '');
    v_desc    text := nullif(btrim(p_voucher ->> 'description'), '');
    v_party   text := nullif(btrim(p_voucher ->> 'counterparty'), '');
    v_line    jsonb;
    v_acc     chart_of_accounts%rowtype;
    v_dr      numeric;
    v_cr      numeric;
    v_tot_dr  numeric := 0;
    v_tot_cr  numeric := 0;
    v_cash_cr numeric := 0;
    v_ref     text;
    v_hdr     journal_headers%rowtype;
    v_id      bigint;
    r         record;
begin
    -- validasi di batas kepercayaan: semua aturan dicek ulang di server
    if v_date is null or v_date > current_date then
        raise exception 'Tanggal voucher wajib diisi dan tidak boleh di masa depan';
    end if;
    if v_by is null or v_desc is null or v_party is null then
        raise exception 'Petugas, uraian, dan penerima pembayaran wajib diisi';
    end if;
    if length(v_by) > 100 or length(v_party) > 100 or length(v_desc) > 500 then
        raise exception 'Isian teks terlalu panjang';
    end if;
    if coalesce(jsonb_typeof(p_voucher -> 'lines'), '') <> 'array' or jsonb_array_length(p_voucher -> 'lines') < 2 then
        raise exception 'Voucher minimal 2 baris jurnal';
    end if;

    for v_line in select * from jsonb_array_elements(p_voucher -> 'lines') loop
        select * into v_acc from chart_of_accounts where account_code = v_line ->> 'account_code';
        if not found then
            raise exception 'Akun % tidak terdaftar', v_line ->> 'account_code';
        end if;
        v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
        v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
        if v_dr <> round(v_dr, 2) or v_cr <> round(v_cr, 2) then
            raise exception 'Nominal maksimal 2 desimal (akun %)', v_acc.account_code;
        end if;
        if v_acc.is_cash and v_dr > 0 then
            raise exception 'Voucher kas keluar tidak boleh mendebit akun kas (%). Gunakan bukti kas masuk.', v_acc.account_name;
        end if;
        v_tot_dr := v_tot_dr + v_dr;
        v_tot_cr := v_tot_cr + v_cr;
        if v_acc.is_cash then v_cash_cr := v_cash_cr + v_cr; end if;
    end loop;

    if v_cash_cr = 0 then
        raise exception 'Voucher kas keluar wajib mengkredit minimal satu akun kas/bank';
    end if;
    if v_tot_dr <> v_tot_cr then
        raise exception 'Zero-discrepancy gagal: debit % <> kredit %', v_tot_dr, v_tot_cr;
    end if;

    -- saldo kas tidak boleh minus: kas hanya keluar sebesar yang tersedia
    for r in
        select a.account_id, a.account_name, sum((x ->> 'credit')::numeric) as keluar
          from jsonb_array_elements(p_voucher -> 'lines') x
          join chart_of_accounts a on a.account_code = x ->> 'account_code'
         where a.is_cash
         group by a.account_id, a.account_name
    loop
        perform pg_advisory_xact_lock(hashtext('cash_' || r.account_id));
        if r.keluar > (select coalesce(sum(l.debit - l.credit), 0)
                         from journal_lines l join journal_headers h using (header_id)
                        where l.account_id = r.account_id and h.status_posting = 'POSTED') then
            raise exception 'Saldo % tidak mencukupi untuk pengeluaran %', r.account_name, r.keluar;
        end if;
    end loop;

    -- nomor bukti berurutan per bulan: BKK-YYYYMM-0001
    perform pg_advisory_xact_lock(hashtext('bkk_' || to_char(v_date, 'YYYYMM')));
    select 'BKK-' || to_char(v_date, 'YYYYMM') || '-' || lpad((count(*) + 1)::text, 4, '0') into v_ref
      from journal_headers where ref_no like 'BKK-' || to_char(v_date, 'YYYYMM') || '-%';

    insert into journal_headers (trx_date, ref_no, description, counterparty, source, created_by)
    values (v_date, v_ref, v_desc, v_party, 'VOUCHER_KK', v_by)
    returning header_id into v_id;

    insert into journal_lines (header_id, account_id, debit, credit, memo)
    select v_id, a.account_id,
           coalesce((x ->> 'debit')::numeric, 0), coalesce((x ->> 'credit')::numeric, 0),
           left(nullif(btrim(x ->> 'memo'), ''), 200)
      from jsonb_array_elements(p_voucher -> 'lines') with ordinality as t(x, n)
      join chart_of_accounts a on a.account_code = x ->> 'account_code'
     order by n;

    update journal_headers set status_posting = 'POSTED', posted_by = v_by
     where header_id = v_id
    returning * into v_hdr;

    return json_build_object('header_id', v_hdr.header_id, 'ref_no', v_hdr.ref_no,
                             'posted_seq', v_hdr.posted_seq, 'hash_checksum', v_hdr.hash_checksum);
end $$;

-- ---------------------------------------------------------------------
-- RPC 2: jurnal pembalik (storno). Jurnal asli tetap utuh; dibuat jurnal baru
-- dengan debit/kredit ditukar dan reversal_of menunjuk ke jurnal asli.
-- ---------------------------------------------------------------------
create or replace function reverse_journal(p_header_id bigint, p_reason text, p_by text) returns json
language plpgsql security definer set search_path = public as $$
declare
    v_src journal_headers%rowtype;
    v_new journal_headers%rowtype;
    v_id  bigint;
begin
    if nullif(btrim(p_reason), '') is null or nullif(btrim(p_by), '') is null then
        raise exception 'Alasan storno dan nama petugas wajib diisi';
    end if;
    select * into v_src from journal_headers where header_id = p_header_id for update;
    if not found or v_src.status_posting <> 'POSTED' then
        raise exception 'Hanya jurnal POSTED yang dapat distorno';
    end if;
    if v_src.reversal_of is not null then
        raise exception 'Jurnal storno tidak dapat distorno lagi';
    end if;
    if exists (select 1 from journal_headers where reversal_of = p_header_id) then
        raise exception 'Jurnal % sudah pernah distorno', v_src.ref_no;
    end if;

    insert into journal_headers (trx_date, ref_no, description, counterparty, source, reversal_of, created_by)
    values (current_date, 'STR-' || v_src.ref_no,
            left('Storno ' || v_src.ref_no || ': ' || btrim(p_reason), 500),
            v_src.counterparty, 'STORNO', v_src.header_id, left(btrim(p_by), 100))
    returning header_id into v_id;

    insert into journal_lines (header_id, account_id, debit, credit, memo)
    select v_id, account_id, credit, debit, 'Pembalik baris #' || line_id
      from journal_lines where header_id = p_header_id order by line_id;

    update journal_headers set status_posting = 'POSTED', posted_by = left(btrim(p_by), 100)
     where header_id = v_id
    returning * into v_new;

    return json_build_object('header_id', v_new.header_id, 'ref_no', v_new.ref_no,
                             'hash_checksum', v_new.hash_checksum);
end $$;

-- ---------------------------------------------------------------------
-- RPC 3: verifikasi integritas (satu jurnal / seluruh rantai)
-- ---------------------------------------------------------------------
create or replace function verify_journal(p_header_id bigint) returns json
language sql stable security definer set search_path = public as $$
    select json_build_object(
        'ref_no', h.ref_no,
        'stored_hash', h.hash_checksum,
        'recomputed_hash', journal_hash(h),
        'hash_valid', h.hash_checksum = journal_hash(h),
        'chain_valid', h.prev_hash is not distinct from
                       (select p.hash_checksum from journal_headers p where p.posted_seq = h.posted_seq - 1))
    from journal_headers h where h.header_id = p_header_id and h.status_posting = 'POSTED'
$$;

create or replace function verify_ledger() returns table (posted_seq bigint, ref_no varchar, hash_valid boolean, chain_valid boolean)
language sql stable security definer set search_path = public as $$
    select h.posted_seq, h.ref_no,
           h.hash_checksum = journal_hash(h),
           h.prev_hash is not distinct from lag(h.hash_checksum) over (order by h.posted_seq)
      from journal_headers h where h.status_posting = 'POSTED' order by h.posted_seq
$$;

-- ---------------------------------------------------------------------
-- Keamanan akses Supabase: klien (anon key) hanya boleh MEMBACA.
-- Semua penulisan wajib lewat RPC di atas (security definer) yang memvalidasi ulang.
-- ---------------------------------------------------------------------
alter table chart_of_accounts      enable row level security;
alter table journal_headers        enable row level security;
alter table journal_lines          enable row level security;
alter table audit_log              enable row level security;
alter table inventory_items        enable row level security;
alter table inventory_transactions enable row level security;

create policy read_all on chart_of_accounts      for select using (true);
create policy read_all on journal_headers        for select using (true);
create policy read_all on journal_lines          for select using (true);
create policy read_all on audit_log              for select using (true);
create policy read_all on inventory_items        for select using (true);
create policy read_all on inventory_transactions for select using (true);

revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;
