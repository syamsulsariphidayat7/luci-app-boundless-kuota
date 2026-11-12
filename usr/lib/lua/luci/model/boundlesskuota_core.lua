-- luci-app-boundless-kuota: inti perhitungan (Lua murni, tanpa
-- dependensi LuCI/OpenWrt supaya bisa diuji di luar STB).
--
-- Semua angka traffic dalam BYTE mentah vnStat. GB selalu DESIMAL
-- (byte / 1e9), mengikuti cara operator menghitung kuota.
--
-- period = {
--   start           = "YYYY-MM-DD",
--   days            = masa aktif (hari),
--   mode            = "blok" | "langsung",
--   base            = biaya dasar (Rp, mode blok),
--   block_gb        = ukuran blok (GB desimal, mode blok),
--   block_rp        = harga per blok (Rp, mode blok),
--   direct_rp       = harga paket (Rp, mode langsung),
--   direct_gb       = kuota paket (GB desimal; 0 = tanpa batas),
--   opening_blocks  = blok tambahan yang sudah terbeli di luar inferensi,
--   correction      = koreksi manual atas blok terbeli (boleh negatif),
-- }
-- days = { { date="YYYY-MM-DD", bytes=N, dl=N, ul=N }, ... } terurut.

local M = {}

local GB = 1000000000

-- ---------- tanggal ----------

function M.parse_date(s)
	if type(s) ~= "string" then return nil end
	local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then return nil end
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	if m < 1 or m > 12 or d < 1 or d > 31 then return nil end
	return y, m, d
end

function M.valid_date(s)
	return M.parse_date(s) ~= nil
end

-- Epoch lokal pukul 00:00 pada tanggal "YYYY-MM-DD".
function M.date_epoch(s)
	local y, m, d = M.parse_date(s)
	if not y then return nil end
	return os.time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 })
end

function M.epoch_date(epoch)
	local t = os.date("*t", epoch)
	return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

-- Selisih hari kalender dari a ke b (b - a), dibulatkan.
function M.day_diff(a, b)
	local ea, eb = M.date_epoch(a), M.date_epoch(b)
	if not ea or not eb then return nil end
	return math.floor((eb - ea) / 86400 + 0.5)
end

function M.add_days(s, n)
	local e = M.date_epoch(s)
	if not e then return nil end
	return M.epoch_date(e + n * 86400)
end

-- ---------- vnStat ----------

-- Ubah daftar hari mentah vnStat (traffic.day) menjadi daftar bersih.
-- flip=true untuk br-lan: label rx/tx vnStat di br-lan kebalik dari
-- arah internet sebenarnya (tx = download, rx = upload).
function M.collect_days(day_array, flip)
	local out = {}
	if type(day_array) ~= "table" then return out end
	for _, e in ipairs(day_array) do
		if type(e) == "table" and type(e.date) == "table" then
			local rx, tx = tonumber(e.rx) or 0, tonumber(e.tx) or 0
			local dl, ul = rx, tx
			if flip then dl, ul = tx, rx end
			out[#out + 1] = {
				date = string.format("%04d-%02d-%02d",
					tonumber(e.date.year) or 0, tonumber(e.date.month) or 0,
					tonumber(e.date.day) or 0),
				bytes = rx + tx,
				dl = dl,
				ul = ul,
			}
		end
	end
	table.sort(out, function(a, b) return a.date < b.date end)
	return out
end

-- ---------- perhitungan ----------

local function ceil_div_bytes(bytes, per)
	if bytes <= 0 then return 0 end
	return math.ceil(bytes / per)
end

-- Blok inferensi dari pemakaian (mode blok).
function M.inferred_blocks(used_bytes, period)
	local per = (tonumber(period.block_gb) or 10) * GB
	if per <= 0 then return 0 end
	return ceil_div_bytes(used_bytes, per)
end

-- Total blok terbeli = inferensi + blok awal + koreksi (mode blok).
function M.total_blocks(used_bytes, period)
	local n = M.inferred_blocks(used_bytes, period)
		+ (tonumber(period.opening_blocks) or 0)
		+ (tonumber(period.correction) or 0)
	if n < 0 then n = 0 end
	return n
end

-- Kuota terbeli (byte) dan biaya menurut skema. purchased=nil berarti
-- tanpa batas (mode langsung dengan direct_gb=0).
function M.purchased_and_paid(used_bytes, period)
	if period.mode == "langsung" then
		local gb = tonumber(period.direct_gb) or 0
		local purchased = nil
		if gb > 0 then purchased = gb * GB end
		return purchased, tonumber(period.direct_rp) or 0, 0
	end
	local blocks = M.total_blocks(used_bytes, period)
	local purchased = blocks * (tonumber(period.block_gb) or 10) * GB
	local paid = (tonumber(period.base) or 0) + blocks * (tonumber(period.block_rp) or 0)
	return purchased, paid, blocks
end

-- Tarif nilai terpakai per byte.
local function used_rate(period)
	if period.mode == "langsung" then
		local gb = tonumber(period.direct_gb) or 0
		if gb <= 0 then return 0 end
		return (tonumber(period.direct_rp) or 0) / (gb * GB)
	end
	local gb = tonumber(period.block_gb) or 10
	if gb <= 0 then return 0 end
	return (tonumber(period.block_rp) or 0) / (gb * GB)
end

-- Biaya tetap yang dibayar di muka pada hari pertama periode.
local function upfront(period)
	if period.mode == "langsung" then
		return tonumber(period.direct_rp) or 0
	end
	return tonumber(period.base) or 0
end

-- Hitung keadaan periode pada jendela [start, end_exclusive).
-- Mengembalikan ringkasan + rincian harian. Dipakai untuk snapshot
-- penutupan maupun (lewat M.compute) periode berjalan.
local function compute_window(all_days, period, end_exclusive)
	local start = period.start
	local rows = {}
	local used, dl, ul = 0, 0, 0
	for _, d in ipairs(all_days) do
		if d.date >= start and d.date < end_exclusive then
			rows[#rows + 1] = d
			used = used + d.bytes
			dl = dl + d.dl
			ul = ul + d.ul
		end
	end

	local purchased, paid, blocks = M.purchased_and_paid(used, period)
	local rate = used_rate(period)
	local up = upfront(period)

	-- Rincian harian: Biaya/Hari mengikuti inferensi blok hari itu
	-- (hari pertama termasuk biaya di muka); Nilai Terpakai/Hari
	-- mengikuti GB hari itu x tarif. Koreksi/blok awal tidak masuk
	-- rincian harian, hanya total periode.
	local daily = {}
	local cum, prev_inf = 0, 0
	for i, d in ipairs(rows) do
		cum = cum + d.bytes
		local inf = 0
		if period.mode ~= "langsung" then
			inf = M.inferred_blocks(cum, period)
		end
		local dcost
		if period.mode == "langsung" then
			dcost = (i == 1) and up or 0
		else
			dcost = (inf - prev_inf) * (tonumber(period.block_rp) or 0)
			if i == 1 then dcost = dcost + up end
		end
		daily[#daily + 1] = {
			date = d.date,
			bytes = d.bytes,
			dl = d.dl,
			ul = d.ul,
			cum_bytes = cum,
			inferred_blocks = inf,
			daily_cost = dcost,
			daily_used_value = d.bytes * rate,
			cum_cost = up + inf * (tonumber(period.block_rp) or 0),
		}
		prev_inf = inf
	end
	if period.mode == "langsung" then
		for _, r in ipairs(daily) do r.cum_cost = up end
	end

	local remain = nil
	if purchased ~= nil then remain = purchased - used end
	local hangus = 0
	if remain ~= nil and remain > 0 then hangus = remain end

	return {
		used_bytes = used,
		dl_bytes = dl,
		ul_bytes = ul,
		blocks = blocks,
		purchased_bytes = purchased,
		paid = paid,
		used_value = up + used * rate,
		remain_bytes = remain,
		hangus_bytes = hangus,
		daily = daily,
		days_with_data = #rows,
	}
end

-- Keadaan periode berjalan.
-- today = "YYYY-MM-DD" hari ini; now_epoch = epoch sekarang (untuk
-- sisa masa aktif pecahan hari pada proyeksi).
function M.compute(all_days, period, today, now_epoch)
	local start = period.start
	local ndays = tonumber(period.days) or 28
	local expiry = M.add_days(start, ndays)
	local expired = today >= expiry
	local end_exclusive = expired and expiry or M.add_days(today, 1)

	local w = compute_window(all_days, period, end_exclusive)

	-- Hari penuh = entri sebelum hari ini di dalam jendela.
	local full_sum, full_count, last7_sum, last7_count = 0, 0, 0, 0
	local full_rows = {}
	for _, r in ipairs(w.daily) do
		if r.date < today then
			full_rows[#full_rows + 1] = r
			full_sum = full_sum + r.bytes
			full_count = full_count + 1
		end
	end
	for i = math.max(1, #full_rows - 6), #full_rows do
		if full_rows[i] then
			last7_sum = last7_sum + full_rows[i].bytes
			last7_count = last7_count + 1
		end
	end

	local today_bytes = 0
	for _, r in ipairs(w.daily) do
		if r.date == today then today_bytes = r.bytes end
	end

	-- Proyeksi (hanya mode blok): rentang dari rata-rata 7 hari penuh
	-- terakhir dan rata-rata seluruh hari penuh periode.
	local projections = nil
	if period.mode ~= "langsung" and full_count > 0 and not expired then
		local expiry_epoch = M.date_epoch(expiry)
		local remain_days = 0
		if expiry_epoch and now_epoch then
			remain_days = (expiry_epoch - now_epoch) / 86400
			if remain_days < 0 then remain_days = 0 end
		end
		local function project(avg_bytes)
			local total = w.used_bytes + avg_bytes * remain_days
			local inf = M.inferred_blocks(total, period)
			local tb = inf + (tonumber(period.opening_blocks) or 0)
				+ (tonumber(period.correction) or 0)
			if tb < w.blocks then tb = w.blocks end
			if tb < 0 then tb = 0 end
			return {
				blocks = tb,
				paid = (tonumber(period.base) or 0) + tb * (tonumber(period.block_rp) or 0),
				add_blocks = tb - w.blocks,
			}
		end
		local avg_all = full_sum / full_count
		local avg_7 = last7_count > 0 and (last7_sum / last7_count) or avg_all
		local p_all = project(avg_all)
		local p_7 = project(avg_7)
		local lo, hi = p_7, p_all
		if lo.paid > hi.paid then lo, hi = hi, lo end
		projections = {
			avg_all_bytes = avg_all,
			avg_7_bytes = avg_7,
			full_days = full_count,
			remain_days = remain_days,
			low = lo,
			high = hi,
		}
	end

	-- Kelengkapan data: hari pertama yang tercatat vnStat untuk
	-- interface ini dibanding tanggal mulai periode.
	local complete, missing_days = true, 0
	if #all_days > 0 and all_days[1].date > start then
		complete = false
		missing_days = M.day_diff(start, all_days[1].date) or 0
	end

	local day_number = (M.day_diff(start, today) or 0) + 1
	if day_number < 1 then day_number = 1 end
	if day_number > ndays then day_number = ndays end

	return {
		start = start,
		expiry = expiry,
		expired = expired,
		day_number = day_number,
		days_total = ndays,
		used_bytes = w.used_bytes,
		dl_bytes = w.dl_bytes,
		ul_bytes = w.ul_bytes,
		blocks = w.blocks,
		purchased_bytes = w.purchased_bytes,
		paid = w.paid,
		used_value = w.used_value,
		eff_price_per_gb = w.used_bytes > 0 and (w.paid / (w.used_bytes / GB)) or 0,
		remain_bytes = w.remain_bytes,
		today_bytes = today_bytes,
		daily = w.daily,
		projections = projections,
		complete = complete,
		missing_days = missing_days,
	}
end

-- Snapshot final periode yang ditutup pada jendela [start, end).
function M.snapshot(all_days, period, end_date)
	local w = compute_window(all_days, period, end_date)
	return {
		start = period.start,
		end_date = end_date,
		duration_days = M.day_diff(period.start, end_date) or 0,
		used_bytes = w.used_bytes,
		dl_bytes = w.dl_bytes,
		ul_bytes = w.ul_bytes,
		blocks = w.blocks,
		purchased_bytes = w.purchased_bytes,
		paid = w.paid,
		hangus_bytes = w.hangus_bytes,
	}
end

return M
