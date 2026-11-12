# luci-app-boundless-kuota

App LuCI untuk memonitor kuota internet GSM (modem di STB OpenWrt)
berdasarkan traffic asli yang lewat STB. Menu: **Services → Monitoring Kuota**.

Beda dengan Sunset: Sunset menampilkan sisa paket menurut operator XL,
app ini mengukur traffic sebenarnya dari **vnStat** yang sudah berjalan
di firmware — app tidak punya database traffic sendiri dan tidak pernah
menulis ke database vnStat.

## Cara kerja

- App membaca `vnstat --json` (harian) untuk interface sumber periode.
- **Periode** dimulai manual lewat tombol *Mulai Periode Baru* (pas beli
  dasar), tanggal mulai bisa dimundurkan; periode lama ditutup sebagai
  **snapshot permanen** di riwayat.
- **Model biaya auto-blok** (bawaan): biaya dasar Rp30.000/28 hari +
  top-up Rp3.000 per blok 10 GB. Blok terbeli disimpulkan otomatis dari
  pemakaian: `ceil(terpakai / 10 GB)` — tanpa input manual per top-up.
  Ada juga mode *Paket Langsung* (sekali beli, mis. Rp50.000/30 hari).
- GB selalu **desimal** (byte / 1e9), mengikuti cara operator menghitung.
- Skema + interface **dibekukan per periode**; perubahan di Pengaturan
  berlaku mulai periode berikutnya.
- Salah pencet periode baru bisa **diurungkan** (periode sebelumnya
  aktif lagi persis seperti semula, snapshot prematur dihapus).
- **Ekspor/Impor Cadangan** JSON untuk riwayat + periode + pengaturan
  app (tidak termasuk database vnStat).

## Interface & PnP

- Pasang pertama: app otomatis memakai **br-lan** untuk periode pertama
  bila vnStat sudah punya datanya (arah RX/TX dibalik: tx br-lan =
  download internet), sekaligus installer mengaktifkan monitoring
  **wwan0** (interface modem beneran).
- Periode berikutnya otomatis memakai **wwan0** (bawaan Pengaturan) —
  data modem yang bersih, mulai tercatat sejak hari aktivasi.
- Sisa kuota adalah perkiraan dari traffic yang lewat STB ini, bukan
  angka resmi operator; angka vnStat tersimpan berkala (±5 menit).

## Pasang

Di STB (satu baris):

```sh
curl -fsSL https://raw.githubusercontent.com/syamsulsariphidayat7/luci-app-boundless-kuota/main/online-install.sh | sh
```

Atau dari salinan lokal repo ini: `sh install.sh` (di dalam STB).

## Copot

```sh
sh /root/luci-app-boundless-kuota-uninstall.sh        # config dipertahankan
sh /root/luci-app-boundless-kuota-uninstall.sh purge  # config ikut dihapus
```

Monitoring wwan0 di vnStat tidak dimatikan saat copot (data vnStat
milik sistem).

## Uji

Inti perhitungan adalah Lua murni (`boundlesskuota_core.lua`) dan diuji
di luar STB memakai fixture database vnStat asli + skenario batas:

```sh
pip install lupa
python3 tests/run_tests.py
python3 tests/controller_sim.py  # simulasi controller (stub UCI + vnStat asli)
```
