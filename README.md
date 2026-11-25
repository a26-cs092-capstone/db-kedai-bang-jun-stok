# Database - Kedai Bang Jun

Database stok bahan baku untuk capstone Asah A26-CS092: **Digitalisasi Pengelolaan Stok Bahan Baku Kedai Bang Jun Samarinda**.
Memakai PostgreSQL di Supabase untuk mencatat bahan baku dan transaksi stok masuk/keluar.

> **Data sintetis.** Seluruh transaksi berasal dari dataset simulasi tim Data Science (90 hari, 1 Agustus - 29 Oktober 2026), bukan transaksi nyata Kedai Bang Jun. Satuan sebagian besar bahan adalah asumsi simulasi. Jangan dipakai sebagai klaim kondisi kedai. Sebelum dipakai sungguhan, ganti dengan data yang benar-benar dicatat di aplikasi (baris yang `is_synthetic = true`).

## Isi repo

| File | Fungsi |
|---|---|
| `schema_v2.sql` | Struktur database: tabel, aturan, penjaga data, dan view |
| `import_dataset.sql` | Mengisi database dari dua file CSV di bawah |
| `bahan_baku.csv` | Master bahan (16 catatan) dari tim DS, folder `01_handoff` |
| `transaksi_stok.csv` | Transaksi simulasi (1.417 baris) dari tim DS, folder `01_handoff` |
| Gambar ERD | Diagram relasi tabel |
| `.env.example` | Contoh isi `.env` untuk koneksi (tanpa rahasia) |

Folder `internal_simulasi` milik tim DS **tidak dipakai** dan memang tidak ada di repo ini.

## ERD

<img src="ERD_CapstoneBangJun.drawio%20(1).png" alt="ERD Kedai Bang Jun" width="420">

Satu bahan baku punya banyak transaksi stok (`bahan_baku` 1 : N `transaksi_stok`). Diagram sengaja disederhanakan; daftar kolom lengkap ada di `schema_v2.sql`.

## Tabel

Nama dan isi kolom mengikuti CSV tim DS.

- **`bahan_baku`**: `ingredient_id` (PK, contoh B001), `ingredient_name`, `category`, `item_type` (INDIVIDUAL/GROUP), `stock_unit`, `is_stockable`, `is_synthetic`, dan kolom keterangan dari DS. Tambahan untuk aplikasi: `stok_minimum` (boleh kosong), `is_aktif`.
- **`transaksi_stok`**: `transaction_id` (PK, contoh TX000001), `transaction_date`, `ingredient_id` (FK), `transaction_type` (MASUK/KELUAR), `quantity` (4 desimal), `unit`, `reason`, `is_synthetic`, `notes`. Tambahan untuk aplikasi: `transaction_time`.

## View (untuk aplikasi)

- **`v_stok_bahan`**: semua kolom bahan + `stok_saat_ini` + `status`.
- **`v_riwayat_stok`**: riwayat transaksi + `ingredient_name`, `stok_sebelum`, dan `stok_sesudah`.

Stok **tidak disimpan sebagai kolom**, selalu dihitung dari transaksi, sehingga tidak bisa berbeda dari riwayatnya.

## Aturan stok

```
stok = total quantity MASUK - total quantity KELUAR
```

- Stok awal adalah transaksi `MASUK` dengan `reason = STOK_AWAL`.
- Pasangan jenis dan alasan yang valid:
  - `MASUK`: `STOK_AWAL`, `PEMBELIAN`
  - `KELUAR`: `PENGGUNAAN`, `RUSAK_TERBUANG`
- Database menolak: stok keluar yang melebihi stok yang ada, satuan transaksi yang beda dari satuan bahan, jumlah nol atau negatif, dan transaksi untuk bahan yang `is_stockable = false` (3 kelompok: Bumbu-bumbu, Saus-saus, Sambal-sambal) atau yang nonaktif.
- Urutan saldo berjalan: `transaction_date`, lalu `transaction_id`.
- Bahan baru dari aplikasi otomatis mendapat ID `B017`, `B018`, dst. Transaksi baru mendapat `TX001418`, dst.

## Cara membuat database

### Opsi A: dengan psql (disarankan)

Jalankan dari folder yang berisi kedua CSV. `DATABASE_URL` adalah connection string Supabase.

```
psql "$DATABASE_URL" -f schema_v2.sql
psql "$DATABASE_URL" -f import_dataset.sql
```

Hasil yang benar: `jumlah_bahan = 16` dan `jumlah_transaksi = 1417`.

### Opsi B: lewat dashboard Supabase

1. Buka **SQL Editor**, tempel isi `schema_v2.sql`, lalu **Run**.
2. Karena kolom ID punya nomor otomatis, impor CSV lewat Table Editor bisa gagal (`COALESCE types text and integer cannot be matched`). Matikan dulu nomor otomatisnya:

```sql
alter table bahan_baku alter column ingredient_id drop default;
alter table transaksi_stok alter column transaction_id drop default;
```

3. Di **Table Editor**, impor `bahan_baku.csv` ke `bahan_baku` lebih dulu, lalu `transaksi_stok.csv` ke `transaksi_stok`.
4. Pasang kembali nomor otomatis dan geser urutannya:

```sql
alter table bahan_baku alter column ingredient_id set default ('B' || lpad(nextval('seq_bahan')::text, 3, '0'));
select setval('seq_bahan', (select max(substr(ingredient_id, 2)::int) from bahan_baku));
alter table transaksi_stok alter column transaction_id set default ('TX' || lpad(nextval('seq_transaksi')::text, 6, '0'));
select setval('seq_transaksi', (select max(substr(transaction_id, 3)::int) from transaksi_stok));
```

## Menyambungkan dari aplikasi

Backend membaca `DATABASE_URL` dari file `.env`. Salin `.env.example` menjadi `.env`, lalu isi dengan connection string dari tombol **Connect** di dashboard Supabase.
**Jangan pernah meng-commit `.env`** atau menaruh password database di repo. Kalau sempat terunggah, ganti password database di Supabase.

## Catatan untuk frontend dan backend

- Form **Stok Masuk** tidak punya field alasan di desain, tapi database mewajibkannya. Isi otomatis dengan `PEMBELIAN`.
- Dropdown **Alasan Stok Keluar** hanya boleh `PENGGUNAAN` dan `RUSAK_TERBUANG`.
- Ambil stok dan status dari `v_stok_bahan`, dan riwayat dari `v_riwayat_stok`.

## Masih asumsi atau menunggu keputusan

- **`stok_minimum` kosong** untuk semua bahan (tidak ada di dataset DS), sehingga `status` sementara `BELUM_DIATUR`.
- **Aturan status** di view hanya asumsi: `Kritis` bila stok <= 50% stok minimum, `Menipis` bila stok <= stok minimum, selain itu `Normal`. Aturan DS berbeda (`AMAN`, `MENIPIS`, `SEGERA_BELI`, berdasarkan rata-rata pemakaian 7 hari) dan belum disepakati dengan Figma.
- **Satuan** (kg, liter, pcs, butir) sebagian besar asumsi simulasi dan perlu dikonfirmasi ke pemilik.
- **Saldo pcs dan butir berdesimal** (mis. kotak makan 399,6589 pcs) karena data sintetis. Belum diputuskan apakah dibulatkan.
- **Alasan penyesuaian stok manual** belum ada di dataset DS.
- **Keamanan akses (RLS)** belum diatur. Cukup untuk data sintetis, perlu dibereskan sebelum ada data asli.
