-- =====================================================================
-- Impor dataset DS (sintetis) ke schema_v2.sql
-- Jalankan dari folder yang berisi bahan_baku.csv dan transaksi_stok.csv
-- (salin dari 01_handoff, hanya dua file itu):
--
--   psql -d nama_database -f schema_v2.sql
--   psql -d nama_database -f import_dataset.sql
--
-- Di Supabase (tanpa psql): Table Editor > pilih tabel > Import data from CSV.
-- Impor bahan_baku dulu, baru transaksi_stok.
-- =====================================================================

\copy bahan_baku (ingredient_id, ingredient_name, category, item_type, source_type, purchase_unit_interview, stock_unit, is_stockable, unit_basis, verification_status, data_source, is_synthetic, notes) FROM 'bahan_baku.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

\copy transaksi_stok (transaction_id, transaction_date, ingredient_id, transaction_type, quantity, unit, reason, data_source, is_synthetic, assumption_id, notes) FROM 'transaksi_stok.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- Transaksi dan bahan baru dari aplikasi melanjutkan nomor setelah dataset (TX001418 dan B017, dst).
SELECT setval('seq_transaksi', (SELECT MAX(substr(transaction_id, 3)::INT) FROM transaksi_stok));
SELECT setval('seq_bahan',     (SELECT MAX(substr(ingredient_id, 2)::INT)  FROM bahan_baku));

-- Pemeriksaan cepat
SELECT (SELECT COUNT(*) FROM bahan_baku)    AS jumlah_bahan,
       (SELECT COUNT(*) FROM transaksi_stok) AS jumlah_transaksi;
