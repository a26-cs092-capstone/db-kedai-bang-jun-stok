-- =====================================================================
-- Kedai Bang Jun - Database Stok Bahan Baku (v2, mengikuti dataset DS)
-- Target: PostgreSQL / Supabase
--
-- Prinsip: dua tabel di bawah SAMA PERSIS dengan dua CSV di 01_handoff
-- (nama kolom, nilai, dan ID dari tim Data Science dipakai apa adanya).
-- Angka turunan (stok saat ini, stok sebelum/sesudah, status) dihitung
-- lewat VIEW, jadi tidak ada angka ganda yang bisa saling bertentangan.
--
-- Rumus stok (dari README DS):
--   stok = SUM(quantity MASUK) - SUM(quantity KELUAR)
-- Stok awal = transaksi MASUK dengan reason STOK_AWAL.
--
-- DATA DI PAKET INI SINTETIS. Sebelum go-live, hapus baris is_synthetic = true.
-- =====================================================================

-- Penomoran bahan baru dari aplikasi melanjutkan format dataset (B017, B018, ...).
-- Setelah impor dataset, sequence digeser oleh import_dataset.sql.
CREATE SEQUENCE IF NOT EXISTS seq_bahan START 17;

CREATE TABLE IF NOT EXISTS bahan_baku (
    -- ---- kolom dari bahan_baku.csv ----
    -- Nilai default di bawah dipakai saat bahan ditambah lewat aplikasi (CSV selalu mengisi sendiri).
    ingredient_id           VARCHAR(10)  PRIMARY KEY
                            DEFAULT ('B' || lpad(nextval('seq_bahan')::TEXT, 3, '0')),   -- contoh: B001
    ingredient_name         VARCHAR(100) NOT NULL UNIQUE,
    category                VARCHAR(50),
    item_type               VARCHAR(12)  NOT NULL DEFAULT 'INDIVIDUAL' CHECK (item_type IN ('INDIVIDUAL', 'GROUP')),
    source_type             VARCHAR(30),
    purchase_unit_interview VARCHAR(30),                              -- boleh kosong
    stock_unit              VARCHAR(20),                              -- kosong untuk GROUP
    is_stockable            BOOLEAN      NOT NULL DEFAULT TRUE,
    unit_basis              VARCHAR(30),
    verification_status     TEXT,
    data_source             VARCHAR(30)  DEFAULT 'APP',
    is_synthetic            BOOLEAN      NOT NULL DEFAULT FALSE,
    notes                   TEXT,
    -- ---- kolom tambahan khusus aplikasi (tidak ada di CSV) ----
    stok_minimum            NUMERIC(12,4) CHECK (stok_minimum IS NULL OR stok_minimum >= 0),  -- NULL = belum ditetapkan
    is_aktif                BOOLEAN      NOT NULL DEFAULT TRUE,       -- soft delete
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),

    -- bahan yang bisa ditransaksikan wajib punya satuan
    CONSTRAINT chk_stockable_punya_satuan CHECK (NOT is_stockable OR stock_unit IS NOT NULL)
);

-- Penomoran transaksi baru dari aplikasi melanjutkan format dataset (TX000001, ...).
-- Setelah impor dataset, sequence digeser oleh import_dataset.sql.
CREATE SEQUENCE IF NOT EXISTS seq_transaksi START 1;

CREATE TABLE IF NOT EXISTS transaksi_stok (
    -- ---- kolom dari transaksi_stok.csv ----
    transaction_id    VARCHAR(20)   PRIMARY KEY
                      DEFAULT ('TX' || lpad(nextval('seq_transaksi')::TEXT, 6, '0')),
    transaction_date  DATE          NOT NULL,
    ingredient_id     VARCHAR(10)   NOT NULL
                      REFERENCES bahan_baku(ingredient_id) ON DELETE RESTRICT,
    transaction_type  VARCHAR(6)    NOT NULL CHECK (transaction_type IN ('MASUK', 'KELUAR')),
    quantity          NUMERIC(12,4) NOT NULL CHECK (quantity > 0),    -- dataset punya sampai 4 desimal
    unit              VARCHAR(20)   NOT NULL,
    reason            VARCHAR(20)   NOT NULL
                      CHECK (reason IN ('STOK_AWAL', 'PEMBELIAN', 'PENGGUNAAN', 'RUSAK_TERBUANG')),
    data_source       VARCHAR(20)   NOT NULL DEFAULT 'APP',           -- dataset: SYNTHETIC
    is_synthetic      BOOLEAN       NOT NULL DEFAULT FALSE,
    assumption_id     VARCHAR(30),
    notes             TEXT,
    -- ---- kolom tambahan khusus aplikasi ----
    transaction_time  TIME,                                           -- jam dari form; kosong untuk data dataset
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),

    -- pasangan jenis dan alasan yang valid (sesuai dataset)
    CONSTRAINT chk_jenis_alasan CHECK (
        (transaction_type = 'MASUK'  AND reason IN ('STOK_AWAL', 'PEMBELIAN')) OR
        (transaction_type = 'KELUAR' AND reason IN ('PENGGUNAAN', 'RUSAK_TERBUANG'))
    )
);

CREATE INDEX IF NOT EXISTS idx_trx_bahan_tanggal ON transaksi_stok (ingredient_id, transaction_date, transaction_id);
CREATE INDEX IF NOT EXISTS idx_trx_tanggal       ON transaksi_stok (transaction_date DESC);

-- ---------------------------------------------------------------------
-- Penjaga data: dijalankan otomatis setiap ada transaksi baru.
--  1. bahan harus aktif dan is_stockable
--  2. satuan transaksi harus sama dengan stock_unit bahan
--  3. stok KELUAR tidak boleh melebihi stok yang ada
-- Baris bahan dikunci (FOR UPDATE) agar dua transaksi bersamaan tidak
-- bisa sama-sama lolos. Pengecekan stok memakai total saldo saat ini,
-- jadi tidak untuk transaksi mundur (backdate) yang menyela riwayat.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_validasi_transaksi() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_unit      VARCHAR;
    v_stockable BOOLEAN;
    v_aktif     BOOLEAN;
    v_saldo     NUMERIC;
BEGIN
    SELECT stock_unit, is_stockable, is_aktif
      INTO v_unit, v_stockable, v_aktif
      FROM bahan_baku
     WHERE ingredient_id = NEW.ingredient_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bahan % tidak ditemukan', NEW.ingredient_id;
    END IF;
    IF NOT v_stockable THEN
        RAISE EXCEPTION 'Bahan % belum bisa ditransaksikan (is_stockable = false)', NEW.ingredient_id;
    END IF;
    IF NOT v_aktif THEN
        RAISE EXCEPTION 'Bahan % sudah nonaktif', NEW.ingredient_id;
    END IF;
    IF NEW.unit IS DISTINCT FROM v_unit THEN
        RAISE EXCEPTION 'Satuan % tidak sama dengan satuan bahan (%)', NEW.unit, v_unit;
    END IF;

    IF NEW.transaction_type = 'KELUAR' THEN
        SELECT COALESCE(SUM(CASE WHEN transaction_type = 'MASUK' THEN quantity ELSE -quantity END), 0)
          INTO v_saldo
          FROM transaksi_stok
         WHERE ingredient_id = NEW.ingredient_id;

        IF v_saldo < NEW.quantity THEN
            RAISE EXCEPTION 'Stok tidak cukup (tersedia %, diminta %)', v_saldo, NEW.quantity;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validasi_transaksi ON transaksi_stok;
CREATE TRIGGER trg_validasi_transaksi
    BEFORE INSERT ON transaksi_stok
    FOR EACH ROW EXECUTE FUNCTION fn_validasi_transaksi();

-- ---------------------------------------------------------------------
-- VIEW untuk aplikasi
-- ---------------------------------------------------------------------

-- Stok saat ini per bahan + status.
-- ASUMSI sementara (belum disepakati dengan DS/owner):
--   stok_minimum NULL         -> BELUM_DIATUR
--   stok <= 50% stok_minimum  -> Kritis
--   stok <= stok_minimum      -> Menipis
--   selain itu                -> Normal
CREATE OR REPLACE VIEW v_stok_bahan AS
SELECT
    b.*,
    COALESCE(SUM(CASE WHEN t.transaction_type = 'MASUK' THEN t.quantity ELSE -t.quantity END), 0) AS stok_saat_ini,
    CASE
        WHEN b.stok_minimum IS NULL THEN 'BELUM_DIATUR'
        WHEN COALESCE(SUM(CASE WHEN t.transaction_type = 'MASUK' THEN t.quantity ELSE -t.quantity END), 0)
             <= b.stok_minimum * 0.5 THEN 'Kritis'
        WHEN COALESCE(SUM(CASE WHEN t.transaction_type = 'MASUK' THEN t.quantity ELSE -t.quantity END), 0)
             <= b.stok_minimum THEN 'Menipis'
        ELSE 'Normal'
    END AS status
FROM bahan_baku b
LEFT JOIN transaksi_stok t ON t.ingredient_id = b.ingredient_id
GROUP BY b.ingredient_id;

-- Riwayat transaksi + stok sebelum/sesudah (untuk halaman Riwayat dan Detail Transaksi).
-- Urutan saldo: tanggal, lalu transaction_id (sesuai README DS).
CREATE OR REPLACE VIEW v_riwayat_stok AS
SELECT
    x.*,
    x.stok_sesudah - CASE WHEN x.transaction_type = 'MASUK' THEN x.quantity ELSE -x.quantity END AS stok_sebelum
FROM (
    SELECT
        t.*,
        b.ingredient_name,
        SUM(CASE WHEN t.transaction_type = 'MASUK' THEN t.quantity ELSE -t.quantity END)
            OVER (PARTITION BY t.ingredient_id ORDER BY t.transaction_date, t.transaction_id) AS stok_sesudah
    FROM transaksi_stok t
    JOIN bahan_baku b ON b.ingredient_id = t.ingredient_id
) x;
