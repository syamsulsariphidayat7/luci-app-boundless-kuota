# luci-app-boundless-kuota

App LuCI untuk mencatat **biaya internet GSM per periode** (modem di
STB OpenWrt), dari angka resmi operator. Menu: **Services → Monitoring Kuota**.

Beda dengan Sunset: Sunset adalah panel transaksinya (OTP, beli paket),
app ini buku catatannya. Sejak 0.4.0 satu-satunya sumber app ini adalah
**API Sunset** — vnStat tidak lagi dibaca sama sekali.

## Cara kerja

- **Sumber API Sunset:** config dipinjam dari app Sunset di STB yang
  sama (`uci sunset.settings`). Terpakai + sisa per paket dari
  `GET /api/luci/welcome`; pembelian resmi XL (semua kanal, status
  SUCCESS) dari `GET /api/luci/history`, diakumulasi lokal (dedupe
  per transaksi) di `/etc/boundlesskuota-api.json`.
- **Segar tiap dibuka, tanpa snapshot latar:** data diambil langsung
  setiap dashboard dimuat — tidak ada cache dan tidak ada cron.
  Keadaan hanya diperbarui saat halaman dibuka; hari tanpa kunjungan
  menyatu ke hari kunjungan berikutnya di tabel harian. Bila API
  tidak terjangkau, dashboard menampilkan data terakhir yang
  tersimpan apa adanya, ditandai basi.
- **Biaya tercatat adalah angka utama:** headline periode berjalan =
  total pembelian tercatat dalam jendela periode, dengan **harga
  riil** — koreksi per transaksi (tombol ✎) menimpa harga katalog XL
  (mis. Xtra Combo Plus katalog Rp35.000 dibayar Rp30.000). Reload /
  isi pulsa **tidak** dihitung: itu pendanaan, bukan pembelian.
  Koreksi harga bertahan lintas periode.
- **Pemakaian harian sadar-reset:** paket add-on (mis. Bonus Kuota
  Instagram 10GB) tidak menumpuk — membeli lagi me-reset bucket ke
  penuh dan sisa lama hangus. Akumulasi membaca penurunan besar
  terpakai bucket sebagai reset (bucket lama dikreditkan habis
  penuh), jadi total terpakai tetap eksak untuk kebiasaan membeli
  saat bucket habis. Paket yang hilang dari daftar operator
  dibekukan pada akumulasi terakhirnya.
- **Harga/GB efektif** = total biaya tercatat ÷ total terpakai
  operator — tersedia sebagai angka periode dan per hari (kumulatif)
  di tabel harian, bersama biaya riil per tanggal pembelian.
- **Sisa** yang ditampilkan adalah sisa bucket yang **aktif
  terpakai** saja (dari angka operator langsung di welcome).
  Kuota khusus yang tidak pernah terpakai trafik pengguna —
  bonus aplikasi lain, kuota 5G, bundling — tidak ikut dihitung
  karena sisa mereka memang tidak bisa dipakai; total semua
  paket tetap ditampilkan sebagai info. Kartu Periode juga
  memuat rincian sisa + terpakai per bucket dari operator.
- **Satuan GB mengikuti operator**: 1 GB = 2^30 byte (biner,
  sama seperti MyXL/Sunset), supaya angka app identik dengan
  angka operator. Bucket di bawah 1 GB tampil dalam MB.
- **Indikator memuat**: bar tipis beranimasi di atas halaman +
  tombol Muat Ulang berubah "Memuat..." dan nonaktif selama
  pengambilan data, supaya jelas data sedang diambil.
- **Penanda isi ulang belum tercatat**: banner kuning muncul
  sendiri bila terpakai mencakup isi ulang bucket yang
  pembeliannya belum muncul di riwayat XL (selisih dari hitungan
  pembelian ≥ 1 GiB) — total biaya saat itu belum termasuk
  pembelian tersebut; banner hilang sendiri begitu transaksinya
  tercatat. Selama banner aktif, di samping total tercatat tampil
  pula perkiraan totalnya (tercatat + tertunda) beserta rincian
  tertundanya — pola add-on yang paling sering dibeli: jumlah
  bucket yang hilang x harga rata-rata efektifnya.
- **Periode** dimulai manual lewat tombol *Mulai Periode Baru* (pas
  beli dasar), tanggal mulai bisa dimundurkan; periode lama ditutup
  sebagai **snapshot permanen** di riwayat — lengkap dengan daftar
  pembeliannya, jadi biaya tiap periode tercatat selamanya walau
  riwayat XL sudah tidak menjangkaunya. Salah pencet bisa
  **diurungkan**.
- **Ekspor/Impor Cadangan** JSON untuk riwayat + periode +
  pengaturan + keadaan API.
- GB selalu **desimal** (byte / 1e9), mengikuti cara operator
  menghitung kuota.

## Pasang

Di STB (satu baris):

```sh
curl -fsSL https://raw.githubusercontent.com/syamsulsariphidayat7/luci-app-boundless-kuota/main/online-install.sh | sh
```

Atau dari salinan lokal repo ini: `sh install.sh` (di dalam STB).
Update ke 0.4.0 otomatis menghapus cron snapshot + berkas snapshot
warisan ≤0.3.x; keadaan API (akumulasi pembelian, kumulatif harian,
koreksi harga) diteruskan apa adanya — periode yang sedang berjalan
tidak terganggu.

## Copot

```sh
sh /root/luci-app-boundless-kuota-uninstall.sh        # config dipertahankan
sh /root/luci-app-boundless-kuota-uninstall.sh purge  # config ikut dihapus
```

## Uji

Inti perhitungan adalah Lua murni (`boundlesskuota_core.lua`);
simulasi controller memakai stub UCI + fixture backend Sunset:

```sh
pip install lupa
python3 tests/run_tests.py
python3 tests/controller_sim.py
```
