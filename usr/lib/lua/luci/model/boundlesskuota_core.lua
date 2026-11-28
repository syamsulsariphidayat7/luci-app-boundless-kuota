-- luci-app-boundless-kuota: inti perhitungan (Lua murni, tanpa
-- dependensi LuCI/OpenWrt supaya bisa diuji di luar STB).
--
-- Sejak 0.4.0 app ini adalah BUKU CATATAN BIAYA per periode, bukan
-- penghitung kuota: satu-satunya sumber adalah API Sunset (backend
-- yang sama dengan luci-app-sunset):
--   * GET /api/luci/welcome -> terpakai + sisa per paket (operator)
--   * GET /api/luci/history -> riwayat transaksi resmi XL
-- vnStat tidak lagi dibaca sama sekali. Satuan GB mengikuti
-- operator: BINER, 1 GB = 2^30 byte (seperti MyXL/Sunset) —
-- terbukti 2026-11-28: bucket "100 GB" berisi 100 x 2^30 byte.
-- Konstanta GB di bawah hanya dipakai harga/GB dan ambang
-- tampilan; akumulasi selalu byte mentah.
--
-- Keadaan API per periode ("api state", disimpan controller sebagai
-- JSON di /etc/boundlesskuota-api.json):
--   state = {
--     period_start = "YYYY-MM-DD",
--     number       = nomor aktif saat ambil terakhir,
--     offset       = byte terpakai yang dipertahankan saat ganti
--                    nomor (reseed); 0 pada periode normal,
--     bmap  = { [kunci paket] = { total, last_used, acc, frozen } },
--     cum   = { ["YYYY-MM-DD"] = terpakai kumulatif periode pada
--               ambil terakhir hari itu },
--     txs   = { [kunci transaksi] = transaksi terakumulasi },
--     price_overrides = { [kunci transaksi] = harga riil (Rp) },
--     last_fetch     = epoch ambil sukses terakhir,
--     last_remaining = sisa operator total (byte) saat ambil itu,
--   }
-- Kunci paket = nama .. "|" .. epoch kedaluwarsa.
--
-- AKUMULASI SADAR-RESET: terpakai paket (benefit) = total - sisa.
-- Paket add-on (mis. Bonus Kuota Instagram 10GB) TIDAK menumpuk:
-- membeli lagi me-reset bucket ke penuh dan sisa lama hangus;
-- pengguna selalu membeli saat bucket habis. Jadi penurunan
-- terpakai yang besar pada kunci yang sama dibaca sebagai reset:
-- bucket lama dikreditkan HABIS PENUH (total), bucket baru dihitung
-- dari nol. Penurunan kecil dibaca sebagai penyesuaian angka
-- operator (acc tidak berubah, last_used mengikuti). Paket yang
-- hilang dari daftar live DIBEKUKAN: akumulasinya dipertahankan.
-- Paket yang pertama terlihat di awal periode tidak dihitung
-- pemakaian lamanya; yang muncul di tengah periode dihitung penuh.
--
-- State warisan 0.3.x (entri bmap ber-baseline, tanpa acc) dimigrasi
-- sebaris: acc = max(0, last_used - baseline).

local M = {}

local GB = 1073741824
M.GB = GB

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

-- ---------- peta paket (welcome) ----------

function M.benefit_key(name, expired)
	return tostring(name or "") .. "|" .. tostring(expired or "")
end

local function benefit_used(b)
	local used = (tonumber(b.total) or 0) - (tonumber(b.remaining) or 0)
	if used < 0 then used = 0 end
	return used
end

-- Migrasi sebaris entri warisan 0.3.x: acc dari baseline.
local function entry_acc(e)
	if e.acc == nil then
		local d = (tonumber(e.last_used) or 0) - (tonumber(e.baseline) or 0)
		e.acc = d > 0 and d or 0
		e.baseline = nil
	end
	return e.acc
end

-- Keadaan awal periode: semua paket live jadi titik awal
-- (pemakaian mereka sebelum periode tidak dihitung).
function M.api_seed(live, offset)
	local st = { offset = tonumber(offset) or 0, bmap = {}, cum = {}, txs = {} }
	for _, b in ipairs(live or {}) do
		st.bmap[b.key] = {
			total = tonumber(b.total) or 0,
			last_used = benefit_used(b),
			acc = 0, frozen = false,
		}
	end
	return st
end

-- Terapkan daftar paket live terbaru ke keadaan (akumulasi
-- sadar-reset; lihat kepala berkas).
function M.api_update(st, live)
	st.bmap = st.bmap or {}
	local seen = {}
	local was_empty = next(st.bmap) == nil
	for _, b in ipairs(live or {}) do
		seen[b.key] = true
		local used = benefit_used(b)
		local e = st.bmap[b.key]
		if e then
			local acc = entry_acc(e)
			local last = tonumber(e.last_used) or 0
			local total_old = tonumber(e.total) or 0
			if used >= last then
				e.acc = acc + (used - last)
			elseif total_old > 0 and (last - used) >= total_old * 0.5 then
				-- Reset: bucket lama habis penuh (kebiasaan beli
				-- saat kosong), bucket baru mulai dari nol.
				e.acc = acc + (total_old - last) + used
			else
				-- Penyesuaian kecil operator: acc tetap, posisi
				-- mengikuti angka terbaru.
				e.acc = acc
			end
			e.total = tonumber(b.total) or 0
			e.last_used = used
			e.frozen = false
		else
			st.bmap[b.key] = {
				total = tonumber(b.total) or 0,
				last_used = used,
				acc = was_empty and 0 or used,
				frozen = false,
			}
		end
	end
	for k, e in pairs(st.bmap) do
		if not seen[k] then e.frozen = true end
	end
	return st
end

-- Total terpakai periode (byte) menurut keadaan API.
function M.api_used(st)
	local total = tonumber(st.offset) or 0
	for _, e in pairs(st.bmap or {}) do
		total = total + entry_acc(e)
	end
	return total
end

-- Sisa satu entri peta paket pada ambil terakhir (byte, >= 0).
local function entry_remaining(e)
	local r = (tonumber(e.total) or 0) - (tonumber(e.last_used) or 0)
	if r < 0 then r = 0 end
	return r
end

-- Bucket "aktif terpakai": terbukti melayani pemakaian — akumulasi
-- periode ini bergerak, atau terpakai siklus berjalannya > 0.
-- Bucket kuota khusus (bonus aplikasi lain, 5G, bundling) yang
-- tidak pernah terpakai TIDAK ikut: sisa mereka tidak bisa dipakai
-- trafik pengguna, jadi mengikutkannya ke sisa menyesatkan.
local function entry_active(e)
	return entry_acc(e) > 0 or (tonumber(e.last_used) or 0) > 0
end

-- Sisa yang bisa dipakai (byte): jumlah sisa bucket aktif terpakai
-- yang masih live (tidak beku). Bila belum ada bucket yang terbukti
-- aktif (awal periode), semua sisa live adalah jawabannya.
function M.usable_remaining(st)
	local active_sum, all_sum = 0, 0
	local any_active = false
	for _, e in pairs(st.bmap or {}) do
		if not e.frozen then
			local r = entry_remaining(e)
			all_sum = all_sum + r
			if entry_active(e) then
				active_sum = active_sum + r
				any_active = true
			end
		end
	end
	if not any_active then return all_sum end
	return active_sum
end

-- Rincian per bucket untuk dashboard: nama diurai dari kunci
-- (nama|epoch kedaluwarsa); used = terpakai siklus berjalan
-- (angka yang sama dengan yang ditampilkan app Sunset).
-- Terurut: aktif dulu, lalu sisa terbesar.
function M.bucket_list(st)
	local list = {}
	for key, e in pairs(st.bmap or {}) do
		list[#list + 1] = {
			name = key:match("^(.*)|[^|]*$") or key,
			total_bytes = tonumber(e.total) or 0,
			remaining_bytes = entry_remaining(e),
			used_bytes = tonumber(e.last_used) or 0,
			acc_bytes = entry_acc(e),
			frozen = e.frozen or false,
			active = entry_active(e),
		}
	end
	table.sort(list, function(a, b)
		if a.active ~= b.active then return a.active end
		return a.remaining_bytes > b.remaining_bytes
	end)
	return list
end

-- ---------- koreksi terpakai satu kali ----------

local function norm_name(s)
	s = tostring(s or ""):lower():gsub("%s+", " ")
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Target terpakai menurut hitungan pembelian: untuk bucket yang
-- punya pembelian tercatat di periode ini, total terpakainya =
-- (jumlah pembelian x total bucket) - sisa sekarang. Itu eksak
-- untuk paket yang selalu dibeli saat habis, dan memperbaiki
-- akumulasi warisan model lama yang kehilangan sebagian
-- pemakaian bucket di era transisi. Bucket tanpa pembelian
-- mempertahankan akumulasinya apa adanya.
-- Judul transaksi dicocokkan ke nama bucket (sama persis atau
-- saling mengandung setelah normalisasi); tiap transaksi hanya
-- diklaim satu bucket (nama terpanjang didahulukan).
-- Target dihitung dari bucket SAJA (offset tidak ikut): delta
-- diterapkan ke offset, jadi offset ditulis ulang menjadi
-- target - total akumulasi bucket. Konsekuensinya pemakaian
-- dari paket yang sudah tidak ada di peta paket sama sekali
-- tidak ikut dalam target — pratinjau menampilkan target dan
-- selisihnya sebelum diterapkan.
-- Mengembalikan { target_bytes, current_bytes, delta_bytes,
-- rows } atau nil bila tak ada pembelian yang cocok.
function M.correction_target(st, purchases)
	local buckets = {}
	for key, e in pairs(st.bmap or {}) do
		buckets[#buckets + 1] = {
			name = key:match("^(.*)|[^|]*$") or key,
			total = tonumber(e.total) or 0,
			remaining = entry_remaining(e),
			acc = entry_acc(e),
			buys = 0,
		}
	end
	table.sort(buckets, function(a, b) return #a.name > #b.name end)
	local claimed, matched_any = {}, false
	for _, b in ipairs(buckets) do
		local bn = norm_name(b.name)
		if #bn >= 8 then
			for i, p in ipairs(purchases or {}) do
				if not claimed[i] then
					local pn = norm_name(p.title)
					if pn ~= "" and (pn == bn
						or bn:find(pn, 1, true) or pn:find(bn, 1, true)) then
						claimed[i] = true
						b.buys = b.buys + 1
					end
				end
			end
		end
		if b.buys > 0 then matched_any = true end
	end
	if not matched_any then return nil end
	local target = 0
	local rows = {}
	for _, b in ipairs(buckets) do
		local tacc = b.acc
		if b.buys > 0 then
			tacc = b.buys * b.total - b.remaining
			if tacc < 0 then tacc = 0 end
			rows[#rows + 1] = {
				name = b.name, buys = b.buys, total_bytes = b.total,
				remaining_bytes = b.remaining, acc_bytes = b.acc,
				target_bytes = tacc,
			}
		end
		target = target + tacc
	end
	local current = M.api_used(st)
	return {
		target_bytes = target, current_bytes = current,
		delta_bytes = target - current, rows = rows,
	}
end

-- Terapkan koreksi: geser offset dan semua titik kumulatif
-- harian dengan delta yang sama — selisih harian tidak berubah,
-- kolom kumulatif naik rata.
function M.apply_correction(st, delta)
	delta = tonumber(delta) or 0
	st.offset = (tonumber(st.offset) or 0) + delta
	st.cum = st.cum or {}
	for d, v in pairs(st.cum) do
		st.cum[d] = (tonumber(v) or 0) + delta
	end
	return st
end

-- Selisih isi ulang yang belum tercatat (byte): pemakaian yang
-- berasal dari isi ulang bucket yang pembeliannya BELUM muncul di
-- riwayat. Memakai hitungan koreksi yang sama — target adalah
-- pemakaian bila hanya pembelian tercatat yang mengisi bucket;
-- kelebihan terpakai aktual di atas target adalah isi ulang yang
-- belum tercatat. Ambang 1 GiB menyaring derau (penyesuaian kecil
-- operator, bucket harian kecil yang reset sendiri). Mengembalikan
-- 0 bila selisihnya di bawah ambang atau tidak bisa dinilai (tak
-- ada pembelian yang cocok dengan bucket mana pun).
function M.unrecorded_gap(st, purchases)
	local t = M.correction_target(st, purchases)
	if not t then return 0 end
	local gap = t.current_bytes - t.target_bytes
	if gap < M.GB then return 0 end
	return gap
end

-- Ganti nomor aktif: total terpakai dipertahankan sebagai offset
-- baru, peta paket disemai ulang dari daftar live nomor baru.
function M.api_reseed(st, live)
	local total = M.api_used(st)
	local fresh = M.api_seed(live, total)
	st.offset = fresh.offset
	st.bmap = fresh.bmap
	return st
end

-- Terpakai kumulatif periode sampai sebelum tanggal end_excl,
-- dari peta kumulatif harian. Bila tidak ada catatan pada/sesudah
-- end_excl, total berjalan adalah jawabannya.
function M.used_until(st, end_excl)
	local best, has_after = nil, false
	for date, cum in pairs(st.cum or {}) do
		if date < end_excl then
			local v = tonumber(cum) or 0
			if not best or v > best then best = v end
		else
			has_after = true
		end
	end
	if has_after then return best or 0 end
	return M.api_used(st)
end

-- Bangun daftar hari { date, bytes } dari kumulatif tercatat
-- (state.cum) + posisi hari ini. Hari tanpa ambil data menyatu ke
-- hari ambil berikutnya (tidak ada snapshot latar sejak 0.4.0:
-- keadaan hanya diperbarui saat dashboard dibuka).
function M.api_days(st, period_start, today)
	local cur = M.api_used(st)
	local pts = {}
	local before = 0
	for date, cum in pairs(st.cum or {}) do
		if date < period_start then
			if (tonumber(cum) or 0) > before then before = tonumber(cum) or 0 end
		elseif date <= today then
			pts[#pts + 1] = { date = date, cum = tonumber(cum) or 0 }
		end
	end
	table.sort(pts, function(a, b) return a.date < b.date end)
	if #pts == 0 or pts[#pts].date ~= today then
		pts[#pts + 1] = { date = today, cum = cur }
	end
	local days = {}
	local prev = before
	for _, p in ipairs(pts) do
		local delta = p.cum - prev
		if delta < 0 then delta = 0 end
		days[#days + 1] = { date = p.date, bytes = delta }
		prev = p.cum
	end
	if #days > 0 and days[1].date > period_start then
		table.insert(days, 1, { date = period_start, bytes = 0 })
	end
	return days
end

-- ---------- riwayat transaksi provider ----------

-- Kunci dedupe transaksi: trx_code bila ada, kalau tidak gabungan
-- timestamp|judul|harga (trx_code XL sering kosong).
function M.tx_key(tx)
	if type(tx) ~= "table" then return nil end
	if tx.trx_code and tx.trx_code ~= "" then return "c:" .. tx.trx_code end
	if tx.timestamp and tx.title then
		return "t:" .. tostring(tx.timestamp) .. "|" .. tostring(tx.title)
			.. "|" .. tostring(tx.price or "")
	end
	return nil
end

function M.tx_is_success(tx)
	return type(tx) == "table" and tx.status == "SUCCESS"
end

-- Gabungkan transaksi hasil ambil terbaru ke akumulasi keadaan.
-- Mengembalikan jumlah transaksi baru.
function M.api_merge_tx(st, fetched)
	st.txs = st.txs or {}
	local added = 0
	for _, tx in ipairs(fetched or {}) do
		local k = M.tx_key(tx)
		if k and not st.txs[k] then
			st.txs[k] = {
				timestamp = tonumber(tx.timestamp),
				title = tx.title or "",
				price = tonumber(tx.price),
				status = tx.status or "",
				payment_status = tx.payment_status or "",
				payment_method = tx.payment_method or "",
			}
			added = added + 1
		end
	end
	return added
end

-- Transaksi paket (bukan isi pulsa): reload/pulsa adalah pendanaan
-- untuk membeli paket, bukan pembelian itu sendiri — menghitungnya
-- juga akan menggandakan biaya yang sama.
local function tx_is_package(tx)
	local t = (tx.title or ""):lower()
	if t:find("reload", 1, true) then return false end
	if t:find("pulsa", 1, true) then return false end
	return true
end

-- Pembelian paket SUCCESS di dalam jendela tanggal [start, end_excl).
-- Harga yang tampil = harga riil: koreksi manual pengguna
-- (st.price_overrides, per kunci transaksi) menimpa harga katalog
-- yang dicatat XL, supaya totalnya = pengeluaran sebenarnya.
function M.api_purchases(st, start_date, end_excl)
	local list, total = {}, 0
	local overrides = st.price_overrides or {}
	for k, tx in pairs(st.txs or {}) do
		if M.tx_is_success(tx) and tx_is_package(tx) and tx.timestamp then
			local d = M.epoch_date(tx.timestamp)
			if d >= start_date and d < end_excl then
				local item = {}
				for kk, vv in pairs(tx) do item[kk] = vv end
				item.key = k
				local ov = tonumber(overrides[k])
				if ov ~= nil then
					item.price_orig = tonumber(tx.price)
					item.price = ov
					item.overridden = true
				end
				list[#list + 1] = item
				total = total + (tonumber(item.price) or 0)
			end
		end
	end
	table.sort(list, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)
	return { list = list, total = total, count = #list }
end

-- Biaya tercatat (harga riil) per tanggal di jendela yang sama:
-- { ["YYYY-MM-DD"] = Rp } untuk kolom biaya tabel harian.
function M.purchases_by_day(st, start_date, end_excl)
	local map = {}
	for _, item in ipairs(M.api_purchases(st, start_date, end_excl).list) do
		local d = M.epoch_date(item.timestamp)
		map[d] = (map[d] or 0) + (tonumber(item.price) or 0)
	end
	return map
end

-- Snapshot final periode yang ditutup pada jendela [start, end):
-- biaya = pembelian tercatat di jendela (harga riil), lengkap
-- dengan daftarnya supaya catatan biaya periode ini permanen
-- walau riwayat XL sudah tidak menjangkaunya lagi. used_bytes
-- ditentukan pemanggil (aturan jendela penutupan di controller).
function M.period_snapshot(st, start, end_excl, used_bytes)
	local purch = M.api_purchases(st, start, end_excl)
	local list = {}
	for _, item in ipairs(purch.list) do
		list[#list + 1] = {
			date = M.epoch_date(item.timestamp),
			title = item.title,
			price = tonumber(item.price) or 0,
			price_orig = item.overridden and (tonumber(item.price_orig) or 0) or nil,
			overridden = item.overridden or nil,
		}
	end
	return {
		start = start,
		end_date = end_excl,
		duration_days = M.day_diff(start, end_excl) or 0,
		used_bytes = tonumber(used_bytes) or 0,
		paid = purch.total,
		purchases_count = purch.count,
		purchases = list,
	}
end

return M
