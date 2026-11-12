-- Uji inti perhitungan boundless-kuota.
-- Dijalankan lewat lupa (Lua di Python) dari tests/run_tests.py.
local HERE = arg and arg[1] or "."
local core = dofile(HERE .. "/usr/lib/lua/luci/model/boundlesskuota_core.lua")
local fixture = dofile(HERE .. "/tests/fixture_days.lua")

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

local GB = 1000000000
local function base_period()
	return {
		start = "2026-10-24", days = 28, mode = "blok",
		base = 30000, block_gb = 10, block_rp = 3000,
		direct_rp = 50000, direct_gb = 0,
		opening_blocks = 0, correction = 0,
	}
end

-- ===== Skenario nyata: br-lan 24 Okt - 12 Nov 2026 (flip arah) =====
local days = core.collect_days(fixture, true)
eq(#days, 20, "nyata: 20 hari")
eq(days[1].date, "2026-10-24", "nyata: hari pertama")
-- br-lan: download = tx vnStat
near(days[1].dl / GB, 12.32, 0.01, "nyata: DL hari pertama dari tx")

local now = os.time({ year = 2026, month = 11, day = 12, hour = 12, min = 45, sec = 0 })
local r = core.compute(days, base_period(), "2026-11-12", now)
near(r.used_bytes / GB, 328.49, 0.01, "nyata: total terpakai 328,49 GB")
near(r.dl_bytes / GB, 286.13, 0.01, "nyata: DL 286,13 GB")
near(r.ul_bytes / GB, 42.36, 0.01, "nyata: UL 42,36 GB")
eq(r.blocks, 33, "nyata: 33 blok")
eq(r.paid, 129000, "nyata: biaya Rp129.000")
near(r.remain_bytes / GB, 1.51, 0.01, "nyata: sisa 1,51 GB")
eq(r.day_number, 20, "nyata: hari ke-20")
eq(r.expiry, "2026-11-21", "nyata: kedaluwarsa 21 Nov")
eq(r.expired, false, "nyata: belum kedaluwarsa")
eq(r.complete, true, "nyata: data lengkap")
eq(#r.daily, 20, "nyata: 20 baris harian")
eq(r.daily[1].daily_cost, 36000, "nyata: Biaya/Hari pertama = dasar + 2 blok")
local sum_daily_cost, sum_used_value = 0, 0
local row_nov8
for _, d in ipairs(r.daily) do
	sum_daily_cost = sum_daily_cost + d.daily_cost
	sum_used_value = sum_used_value + d.daily_used_value
	if d.date == "2026-11-08" then row_nov8 = d end
end
eq(sum_daily_cost, 129000, "nyata: jumlah Biaya/Hari = biaya kumulatif")
near(sum_used_value, 98546, 2, "nyata: jumlah Nilai Terpakai/Hari = 98.546")
eq(row_nov8.daily_cost, 0, "nyata: 8 Nov tanpa blok baru = Rp0")
eq(r.daily[20].cum_cost, 129000, "nyata: Biaya Kumulatif terakhir 129.000")
near(r.projections.avg_all_bytes / GB, 16.6903, 0.001, "nyata: rata-rata periode")
near(r.projections.avg_7_bytes / GB, 13.892, 0.001, "nyata: rata-rata 7 hari")
eq(r.projections.low.paid, 165000, "nyata: proyeksi rendah Rp165.000")
eq(r.projections.high.paid, 171000, "nyata: proyeksi tinggi Rp171.000")
eq(r.projections.low.add_blocks, 12, "nyata: blok tambahan rendah 12")
eq(r.projections.high.add_blocks, 14, "nyata: blok tambahan tinggi 14")

-- Snapshot penutupan pada 13 Nov (jendela [24 Okt, 13 Nov))
local snap = core.snapshot(days, base_period(), "2026-11-13")
eq(snap.duration_days, 20, "snapshot: durasi 20 hari")
near(snap.used_bytes / GB, 328.49, 0.01, "snapshot: terpakai sama")
near(snap.hangus_bytes / GB, 1.51, 0.01, "snapshot: hangus 1,51 GB")
eq(snap.paid, 129000, "snapshot: biaya 129.000")

-- Snapshot anti dobel hitung: berakhir 10 Nov tidak memuat 10 Nov.
local snap2 = core.snapshot(days, base_period(), "2026-11-10")
eq(snap2.duration_days, 17, "snapshot2: durasi 17 hari")
near(snap2.used_bytes / GB, 297.41, 0.01, "snapshot2: terpakai s/d 9 Nov")

-- ===== Skenario batas Syamsul: 20 + 5 + 2 GB =====
local function mkdays(list)
	local out = {}
	for i, gb in ipairs(list) do
		out[#out + 1] = { date = string.format("2026-11-%02d", i), bytes = gb * GB, dl = gb * GB, ul = 0 }
	end
	return out
end
local p3 = base_period(); p3.start = "2026-11-01"
local r1 = core.compute(mkdays({ 20 }), p3, "2026-11-01", now)
eq(r1.blocks, 2, "batas: 20 GB = 2 blok")
eq(r1.paid, 36000, "batas: 20 GB = Rp36.000")
local r2 = core.compute(mkdays({ 20, 5 }), p3, "2026-11-02", now)
eq(r2.blocks, 3, "batas: kumulatif 25 GB = 3 blok")
eq(r2.paid, 39000, "batas: 25 GB = Rp39.000")
local r3 = core.compute(mkdays({ 20, 5, 2 }), p3, "2026-11-03", now)
eq(r3.blocks, 3, "batas: kumulatif 27 GB tetap 3 blok")
eq(r3.paid, 39000, "batas: 27 GB tetap Rp39.000")
near(r3.remain_bytes / GB, 3, 0.001, "batas: sisa 3 GB")
local r4 = core.compute(mkdays({ 30 }), p3, "2026-11-01", now)
eq(r4.blocks, 3, "batas: pas 30,0 GB = 3 blok")
local r5 = core.compute(mkdays({ 30.1 }), p3, "2026-11-01", now)
eq(r5.blocks, 4, "batas: 30,1 GB = 4 blok")
eq(r5.paid, 42000, "batas: 30,1 GB = Rp42.000")

-- ===== Koreksi & blok awal =====
local pc = base_period(); pc.start = "2026-11-01"; pc.correction = 1
local rc = core.compute(mkdays({ 27 }), pc, "2026-11-01", now)
eq(rc.blocks, 4, "koreksi: 27 GB + koreksi 1 = 4 blok")
eq(rc.paid, 42000, "koreksi: biaya ikut naik")
local po = base_period(); po.start = "2026-11-01"; po.opening_blocks = 2
local ro = core.compute(mkdays({ 0 }), po, "2026-11-01", now)
eq(ro.blocks, 2, "blok awal: 0 GB + 2 blok awal = 2 blok")
near(ro.remain_bytes / GB, 20, 0.001, "blok awal: terbeli 20 GB")

-- ===== Mode paket langsung =====
local pd = base_period(); pd.mode = "langsung"; pd.direct_rp = 50000; pd.direct_gb = 100
local rd = core.compute(mkdays({ 40 }), pd, "2026-11-01", now)
eq(rd.paid, 50000, "langsung: biaya tetap Rp50.000")
near(rd.purchased_bytes / GB, 100, 0.001, "langsung: terbeli 100 GB")
near(rd.remain_bytes / GB, 60, 0.001, "langsung: sisa 60 GB")
local sd = core.snapshot(mkdays({ 40 }), pd, "2026-11-02")
near(sd.hangus_bytes / GB, 60, 0.001, "langsung: hangus 60 GB saat ditutup")
local pu = base_period(); pu.mode = "langsung"; pu.direct_rp = 50000; pu.direct_gb = 0
local ru = core.compute(mkdays({ 40 }), pu, "2026-11-01", now)
eq(ru.purchased_bytes, nil, "langsung tanpa batas: purchased nil")
eq(ru.remain_bytes, nil, "langsung tanpa batas: remain nil")

-- ===== Kedaluwarsa & kelengkapan =====
local re = core.compute(days, base_period(), "2026-11-25", now)
eq(re.expired, true, "lewat 21 Nov: kedaluwarsa")
eq(re.day_number, 28, "kedaluwarsa: hari ditahan di 28")
near(re.used_bytes / GB, 328.49, 0.01, "kedaluwarsa: pemakaian berhenti di jendela periode")
local pw = base_period(); pw.start = "2026-10-20"
local rw = core.compute(days, pw, "2026-11-12", now)
eq(rw.complete, false, "mulai sebelum data vnStat: tidak lengkap")
eq(rw.missing_days, 4, "tidak lengkap: 4 hari hilang (20-23 Okt)")

print(string.format("HASIL: %d lulus, %d gagal", pass, fail))
TEST_FAIL = fail
