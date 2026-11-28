-- Uji inti perhitungan boundless-kuota 0.4.0 (sumber API Sunset:
-- akumulasi sadar-reset + riwayat transaksi + snapshot biaya).
-- Dijalankan lewat lupa (Lua di Python) dari tests/run_tests.py.
local HERE = arg and arg[1] or "."
local core = dofile(HERE .. "/usr/lib/lua/luci/model/boundlesskuota_core.lua")

local pass, fail = 0, 0
local function ok(cond, name)
	if cond then
		pass = pass + 1
	else
		fail = fail + 1
		print("GAGAL: " .. name)
	end
end
local function eq(a, b, name)
	ok(a == b, string.format("%s (dapat %s, mau %s)", name, tostring(a), tostring(b)))
end
local function near(a, b, tol, name)
	ok(math.abs(a - b) <= tol, string.format("%s (dapat %.4f, mau %.4f ±%s)",
		name, a, b, tostring(tol)))
end

local GB = 1073741824
local function benefit(name, total_gb, rem_gb, exp)
	return { key = core.benefit_key(name, exp or 111), total = total_gb * GB, remaining = rem_gb * GB }
end

-- ===== Tanggal =====
eq(core.add_days("2026-11-21", 28), "2026-12-19", "tanggal: +28 hari")
eq(core.day_diff("2026-11-21", "2026-12-19"), 28, "tanggal: selisih 28")

-- ===== Akumulasi dasar (model baseline penerus 0.3.x) =====
local st = core.api_seed({ benefit("Dasar", 500, 400) }, 298.49 * GB)
near(core.api_used(st) / GB, 298.49, 0.001, "api: seed = offset saja (paket = titik awal)")
core.api_update(st, { benefit("Dasar", 500, 395) })
near(core.api_used(st) / GB, 303.49, 0.001, "api: +5 GB dari paket awal")
core.api_update(st, { benefit("Dasar", 500, 395), benefit("Blok", 10, 8, 222) })
near(core.api_used(st) / GB, 305.49, 0.001, "api: paket baru di tengah periode +2 GB penuh")
core.api_update(st, { benefit("Dasar", 500, 390) })
near(core.api_used(st) / GB, 310.49, 0.001, "api: paket hilang dibekukan (+5 GB dasar)")
core.api_reseed(st, { benefit("Baru", 100, 100, 333) })
near(core.api_used(st) / GB, 310.49, 0.001, "api: reseed mempertahankan total")

-- ===== Akumulasi sadar-reset (bucket add-on tidak menumpuk) =====
-- Bucket IG 10 GB: terpakai naik 0 -> 4 -> 10 (habis), beli lagi
-- (reset ke penuh, terpakai 0), lalu terpakai 3. Total riil = 13.
local ig = core.api_seed({ benefit("IG", 10, 10, 999) }, 0)
eq(core.api_used(ig), 0, "reset: awal 0")
core.api_update(ig, { benefit("IG", 10, 6, 999) })
near(core.api_used(ig) / GB, 4, 0.001, "reset: terpakai 4")
core.api_update(ig, { benefit("IG", 10, 0, 999) })
near(core.api_used(ig) / GB, 10, 0.001, "reset: bucket habis = 10")
core.api_update(ig, { benefit("IG", 10, 10, 999) })
near(core.api_used(ig) / GB, 10, 0.001, "reset: sesudah beli lagi tetap 10 (bucket lama habis penuh)")
core.api_update(ig, { benefit("IG", 10, 7, 999) })
near(core.api_used(ig) / GB, 13, 0.001, "reset: bucket baru terpakai 3 -> total 13")
-- Reset tertangkap di tengah pendakian: snapshot terakhir 7,
-- berikutnya bucket baru sudah terpakai 1 (turun 6 >= separuh
-- bucket) -> bucket lama dikreditkan penuh: 10 + 1 = 11.
local ig2 = core.api_seed({ benefit("IG", 10, 10, 999) }, 0)
core.api_update(ig2, { benefit("IG", 10, 3, 999) })
near(core.api_used(ig2) / GB, 7, 0.001, "reset2: terpakai 7")
core.api_update(ig2, { benefit("IG", 10, 9, 999) })
near(core.api_used(ig2) / GB, 11, 0.001, "reset2: reset di tengah -> 10 penuh + 1 = 11")
-- Penurunan kecil = penyesuaian operator, bukan reset:
-- 7 -> 6,5 tidak menambah apa pun; naik lagi ke 8 dihitung dari 6,5.
local ig3 = core.api_seed({ benefit("IG", 10, 10, 999) }, 0)
core.api_update(ig3, { benefit("IG", 10, 3, 999) })
core.api_update(ig3, { benefit("IG", 10, 3.5, 999) })
near(core.api_used(ig3) / GB, 7, 0.001, "sesuaian: turun kecil tidak mengubah akumulasi")
core.api_update(ig3, { benefit("IG", 10, 2, 999) })
near(core.api_used(ig3) / GB, 8.5, 0.001, "sesuaian: kenaikan berikutnya dari posisi baru")

-- ===== Migrasi state warisan 0.3.x (baseline -> acc) =====
local legacy = {
	offset = 0, cum = {}, txs = {},
	bmap = { ["Lama|1"] = { total = 500 * GB, last_used = 95 * GB, baseline = 90 * GB, frozen = false } },
}
near(core.api_used(legacy) / GB, 5, 0.001, "warisan: acc = last_used - baseline = 5")
core.api_update(legacy, { benefit("Lama", 500, 400, 1) })
near(core.api_used(legacy) / GB, 10, 0.001, "warisan: pertumbuhan sesudah migrasi +5")

-- ===== Kumulatif harian + used_until =====
local st2 = core.api_seed({ benefit("Dasar", 500, 400) }, 0)
core.api_update(st2, { benefit("Dasar", 500, 390) })
st2.cum = { ["2026-10-31"] = 2 * GB, ["2026-11-01"] = 4 * GB, ["2026-11-02"] = 7 * GB }
local adays = core.api_days(st2, "2026-11-01", "2026-11-03")
eq(#adays, 3, "api_days: 3 hari terbangun")
near(adays[1].bytes / GB, 2, 0.001, "api_days: hari pertama dikurangi garis dasar")
near(adays[2].bytes / GB, 3, 0.001, "api_days: delta hari kedua 3 GB")
near(adays[3].bytes / GB, 3, 0.001, "api_days: hari ini = posisi terakhir")
near(core.used_until(st2, "2026-11-02") / GB, 4, 0.001, "used_until: kumulatif sebelum 2 Nov")
near(core.used_until(st2, "2026-11-04") / GB, 10, 0.001, "used_until: sesudah semua catatan = total")

-- ===== Riwayat: dedupe, filter SUCCESS, saring reload, override =====
local function noon(y, m, d) return os.time({ year = y, month = m, day = d, hour = 12 }) end
local txs1 = {
	{ timestamp = noon(2026, 10, 22), title = "Dasar", price = 30000, status = "SUCCESS", trx_code = "A1" },
	{ timestamp = noon(2026, 10, 22), title = "Blok", price = 3000, status = "SUCCESS", trx_code = "A2" },
	{ timestamp = noon(2026, 10, 22), title = "Blok", price = 3000, status = "FAILED", trx_code = "A3" },
	{ timestamp = noon(2026, 10, 22), title = "Blok", price = 3000, status = "REFUND", trx_code = "" },
	{ timestamp = noon(2026, 10, 25), title = "Blok", price = 3000, status = "SUCCESS", trx_code = "A5" },
	{ timestamp = noon(2026, 10, 22), title = "Reload", price = 25000, status = "SUCCESS", trx_code = "A6" },
}
eq(core.api_merge_tx(st, txs1), 6, "tx: 6 transaksi pertama masuk")
eq(core.api_merge_tx(st, txs1), 0, "tx: ambil ulang = 0 baru (dedupe)")
local purch = core.api_purchases(st, "2026-10-21", "2026-10-23")
eq(purch.count, 2, "tx: purchases hanya SUCCESS paket di jendela (Reload tersaring)")
eq(purch.total, 33000, "tx: total purchases Rp33.000 (Reload Rp25.000 tidak ikut)")
local byd = core.purchases_by_day(st, "2026-10-21", "2026-10-23")
eq(byd["2026-10-22"], 33000, "tx: biaya per hari 22 Okt Rp33.000")
-- Koreksi harga riil: katalog 30.000 dibayar 25.000.
st.price_overrides = { ["c:A1"] = 25000 }
local purch2 = core.api_purchases(st, "2026-10-21", "2026-10-23")
eq(purch2.total, 28000, "tx: override harga -> total pengeluaran riil Rp28.000")
local found_ov = false
for _, it in ipairs(purch2.list) do
	if it.key == "c:A1" and it.overridden and it.price == 25000 and it.price_orig == 30000 then found_ov = true end
end
eq(found_ov, true, "tx: baris override bertanda, harga riil + harga katalog tersimpan")
eq(core.purchases_by_day(st, "2026-10-21", "2026-10-23")["2026-10-22"], 28000,
	"tx: biaya per hari ikut harga riil")

-- ===== Snapshot periode (biaya tercatat + daftar permanen) =====
local st3 = core.api_seed({ benefit("Dasar", 500, 500) }, 0)
core.api_update(st3, { benefit("Dasar", 500, 491) })
st3.cum = { ["2026-10-22"] = 5 * GB, ["2026-10-23"] = 9 * GB }
core.api_merge_tx(st3, {
	{ timestamp = os.time({ year = 2026, month = 10, day = 22, hour = 9 }), title = "Dasar", price = 30000, status = "SUCCESS", trx_code = "S1" },
	{ timestamp = noon(2026, 10, 22), title = "Blok", price = 3000, status = "SUCCESS", trx_code = "S2" },
	{ timestamp = noon(2026, 10, 26), title = "Blok", price = 3000, status = "SUCCESS", trx_code = "S3" },
})
local snap = core.period_snapshot(st3, "2026-10-21", "2026-10-24", core.used_until(st3, "2026-10-24"))
eq(snap.duration_days, 3, "snapshot: durasi 3 hari")
near(snap.used_bytes / GB, 9, 0.001, "snapshot: terpakai s/d akhir jendela 9 GB")
eq(snap.paid, 33000, "snapshot: biaya = pembelian tercatat di jendela")
eq(snap.purchases_count, 2, "snapshot: 2 pembelian (26 Okt di luar jendela)")
eq(#snap.purchases, 2, "snapshot: daftar pembelian ikut tersimpan")
eq(snap.purchases[1].date, "2026-10-22", "snapshot: tanggal pembelian pertama")
eq(snap.purchases[1].price, 30000, "snapshot: harga pembelian pertama")

-- ===== Sisa terpakai + rincian bucket (0.4.1) =====
local stb = core.api_seed({ benefit("IG", 10, 10, 999), benefit("Bonus5G", 100, 100, 888) }, 0)
near(core.usable_remaining(stb) / GB, 110, 0.001, "sisa: belum ada aktivitas -> semua sisa live")
core.api_update(stb, { benefit("IG", 10, 6, 999), benefit("Bonus5G", 100, 100, 888) })
near(core.usable_remaining(stb) / GB, 6, 0.001, "sisa: hanya bucket aktif terpakai (IG 6 GB; 5G 100 GB dikecualikan)")
local bl = core.bucket_list(stb)
eq(#bl, 2, "bucket: 2 entri")
eq(bl[1].name, "IG", "bucket: aktif terurut pertama, nama terurai dari kunci")
eq(bl[1].active, true, "bucket: IG aktif")
eq(bl[2].active, false, "bucket: 5G tidak aktif")
near(bl[2].remaining_bytes / GB, 100, 0.001, "bucket: sisa 5G tetap terlihat di rincian")
-- Bucket aktif yang membeku dikeluarkan dari sisa terpakai.
local stf = core.api_seed({ benefit("A", 10, 10, 1), benefit("B", 10, 10, 2) }, 0)
core.api_update(stf, { benefit("A", 10, 5, 1), benefit("B", 10, 5, 2) })
core.api_update(stf, { benefit("A", 10, 4, 1) })
near(core.usable_remaining(stf) / GB, 4, 0.001, "sisa: bucket beku (B) dikeluarkan, tinggal A 4 GB")

-- ===== Koreksi terpakai satu kali (0.4.3) =====
local stk = { offset = 0, bmap = {}, cum = {}, txs = {} }
stk.bmap["Bonus Kuota Instagram 10GB|999"] = { total = 10 * GB, last_used = 8 * GB, acc = 65 * GB, frozen = false }
stk.bmap["Quota Bonus 5G|888"] = { total = 100 * GB, last_used = 0, acc = 0, frozen = false }
stk.cum["2026-11-27"] = 60 * GB
local purch9 = {}
for i = 1, 9 do purch9[i] = { title = "Bonus Kuota Instagram 10GB" } end
local corr = core.correction_target(stk, purch9)
eq(corr ~= nil, true, "koreksi: target terhitung")
near(corr.current_bytes / GB, 65, 0.001, "koreksi: tercatat sekarang 65 GB (warisan kurang)")
near(corr.target_bytes / GB, 88, 0.001, "koreksi: target = 9x10 - sisa 2 = 88 GB")
near(corr.delta_bytes / GB, 23, 0.001, "koreksi: delta +23 GB")
eq(corr.rows[1].buys, 9, "koreksi: 9 pembelian IG terklaim untuk bucket IG")
core.apply_correction(stk, corr.delta_bytes)
near(core.api_used(stk) / GB, 88, 0.001, "koreksi: sesudah diterapkan terpakai = 88 GB")
near(stk.cum["2026-11-27"] / GB, 83, 0.001, "koreksi: titik kumulatif ikut bergeser rata")
local corr2 = core.correction_target(stk, purch9)
near(corr2.delta_bytes, 0, 0.001, "koreksi: idempoten — hitung ulang delta 0")
local corr3 = core.correction_target(
	{ offset = 0, cum = {}, bmap = { ["Bonus Kuota Instagram 10GB|1"] = { total = 10 * GB, last_used = 10 * GB, acc = 0, frozen = false } } },
	{ { title = "  bonus kuota instagram 10gb " } })
eq(corr3.rows[1].buys, 1, "koreksi: judul ternormalisasi (huruf/spasi) tetap cocok")
eq(core.correction_target(stk, { { title = "Paket Lain Sekali" } }), nil,
	"koreksi: tidak ada pembelian cocok -> nil")

-- ===== Selisih isi ulang belum tercatat (0.4.7) =====
-- Replika kasus live: akumulasi 91 GB dari 10 isi (sisa 9 GB),
-- tapi riwayat baru mencatat 9 pembelian -> selisih tepat 10 GB.
local stg = { offset = 0, bmap = {}, cum = {}, txs = {} }
stg.bmap["Bonus Kuota Instagram 10GB|999"] = { total = 10 * GB, last_used = 1 * GB, acc = 91 * GB, frozen = false }
near(core.unrecorded_gap(stg, purch9) / GB, 10, 0.001, "gap: 10 isi vs 9 tercatat -> 10 GB")
local purch10 = {}
for i = 1, 10 do purch10[i] = { title = "Bonus Kuota Instagram 10GB" } end
eq(core.unrecorded_gap(stg, purch10), 0, "gap: 10 isi vs 10 tercatat -> 0")
-- Selisih 0,5 GB di bawah ambang 1 GiB -> 0 (derau, bukan isi ulang).
local stg2 = { offset = 0, bmap = {}, cum = {}, txs = {} }
stg2.bmap["Bonus Kuota Instagram 10GB|999"] = { total = 10 * GB, last_used = 1 * GB, acc = 81 * GB + GB / 2, frozen = false }
eq(core.unrecorded_gap(stg2, purch9), 0, "gap: selisih 0,5 GB di bawah ambang -> 0")
eq(core.unrecorded_gap(stg, { { title = "Paket Lain Sekali" } }), 0,
	"gap: tanpa pembelian cocok -> 0")

print(string.format("HASIL: %d lulus, %d gagal", pass, fail))
TEST_FAIL = fail
