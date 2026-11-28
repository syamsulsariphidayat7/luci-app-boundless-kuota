module("luci.controller.boundlesskuota", package.seeall)

-- luci-app-boundless-kuota: buku catatan biaya internet GSM per
-- periode. Controller melayani dashboard (Services -> Monitoring
-- Kuota) dan endpoint JSON-nya:
--   GET  status   -> seluruh keadaan dashboard (periode, riwayat)
--   POST start    -> tutup periode berjalan (snapshot) + mulai baru;
--                    tanpa periode aktif: buat periode pertama
--   POST undo     -> urungkan periode baru terakhir (pulihkan sebelumnya)
--   POST txprice  -> koreksi harga riil satu transaksi tercatat
--   POST settings -> simpan masa aktif untuk periode berikutnya
--   GET  export   -> unduh cadangan JSON (riwayat + periode + pengaturan)
--   POST import   -> pulihkan cadangan JSON
--   POST reset    -> hapus semua data app (pengaturan dipertahankan)
--   GET  version / check, POST update, GET updatelog (Versi & Update)
-- Perhitungan murni ada di luci.model.boundlesskuota_core.
--
-- Sejak 0.4.0 satu-satunya sumber adalah API Sunset (backend yang
-- sama dengan luci-app-sunset, config dipinjam dari UCI sunset):
-- terpakai + sisa dari /api/luci/welcome (angka operator), pembelian
-- dari /api/luci/history. vnStat tidak lagi dibaca. Data diambil
-- SEGAR setiap status dimuat (tanpa cache, tanpa cron snapshot);
-- keadaan API disimpan di berkas JSON /etc/boundlesskuota-api.json
-- (env BK_API_STATE menimpanya, untuk pengujian). Bila API tidak
-- terjangkau, dashboard menampilkan keadaan terakhir yang tersimpan
-- apa adanya (ditandai basi), bukan angka karangan.
function index()
	if not nixio.fs.access("/etc/config/boundlesskuota") then
		return
	end
	entry({"admin", "services", "boundlesskuota"},
		template("boundlesskuota/dashboard"), "Monitoring Kuota", 93)
	entry({"admin", "services", "boundlesskuota", "status"},
		call("action_status")).leaf = true
	entry({"admin", "services", "boundlesskuota", "start"},
		post("action_start")).leaf = true
	entry({"admin", "services", "boundlesskuota", "undo"},
		post("action_undo")).leaf = true
	entry({"admin", "services", "boundlesskuota", "txprice"},
		post("action_txprice")).leaf = true
	entry({"admin", "services", "boundlesskuota", "settings"},
		post("action_settings")).leaf = true
	entry({"admin", "services", "boundlesskuota", "export"},
		call("action_export")).leaf = true
	entry({"admin", "services", "boundlesskuota", "import"},
		post("action_import")).leaf = true
	entry({"admin", "services", "boundlesskuota", "reset"},
		post("action_reset")).leaf = true
	entry({"admin", "services", "boundlesskuota", "version"},
		call("action_version")).leaf = true
	entry({"admin", "services", "boundlesskuota", "check"},
		call("action_check")).leaf = true
	entry({"admin", "services", "boundlesskuota", "update"},
		post("action_update")).leaf = true
	entry({"admin", "services", "boundlesskuota", "updatelog"},
		call("action_updatelog")).leaf = true
end

local core = require "luci.model.boundlesskuota_core"

local CONFIG        = "boundlesskuota"
local REPO_SLUG     = "syamsulsariphidayat7/luci-app-boundless-kuota"
local REPO_API      = "https://api.github.com/repos/" .. REPO_SLUG
local REPO_RAW      = "https://raw.githubusercontent.com/" .. REPO_SLUG
local VERSION_FILE  = "/usr/lib/lua/luci/view/boundlesskuota/VERSION"
local UPDATE_LOG    = "/tmp/boundlesskuota-update.log"
local UPDATE_RC     = "/tmp/boundlesskuota-update.rc"
local UPDATE_PID    = "/tmp/boundlesskuota-update.pid"
local UPDATE_SCRIPT = "/tmp/boundlesskuota-online-install.sh"

local SETTINGS_KEYS = { "days" }
local PERIOD_KEYS   = { "start", "days" }
local SNAPSHOT_KEYS = { "start", "end_date", "duration_days", "used_bytes",
	"paid", "purchases_count", "purchases" }

local DEFAULTS = { days = "28" }

-- ---------- util umum (pola luci-app-boundless-tools) ----------

local function write_json(tbl, status)
	if status then luci.http.status(status, status == 400 and "Bad Request" or "Error") end
	luci.http.prepare_content("application/json")
	luci.http.write(luci.jsonc.stringify(tbl))
end

local function require_post()
	local disp = luci.dispatcher
	if disp and disp.test_post_security then
		return disp.test_post_security()
	end
	if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
		luci.http.status(405, "Method Not Allowed")
		return false
	end
	local tok  = luci.http.formvalue("token")
	local want = disp and disp.context and disp.context.authtoken
	if tok and want and tok == want then
		return true
	end
	luci.http.status(403, "Forbidden")
	return false
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function read_tail(path, max)
	local f = io.open(path, "rb")
	if not f then return "" end
	local size = f:seek("end") or 0
	local off = size - max
	if off < 0 then off = 0 end
	f:seek("set", off)
	local data = f:read("*a") or ""
	f:close()
	return data
end

local function read_trim(path)
	local s = read_file(path)
	if not s then return nil end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	return s
end

local function installed_version()
	local v = read_trim(VERSION_FILE)
	if not v then return "?" end
	return (v:gsub("^v", ""))
end

local function fetch_text(url)
	local out = luci.sys.exec(string.format(
		"if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 6 --max-time 20 %s; "
		.. "elif command -v wget >/dev/null 2>&1; then wget -qO- --timeout=20 %s; fi 2>/dev/null",
		luci.util.shellquote(url), luci.util.shellquote(url)))
	return out or ""
end

local function latest_tag()
	local out = fetch_text(REPO_API .. "/tags?per_page=1")
	if not out or out == "" then return nil end
	local tag = out:match('"name"%s*:%s*"([^"]+)"')
	if not tag or tag == "" then return nil end
	return tag
end

local function update_running()
	if read_trim(UPDATE_RC) then return false end
	local pid = read_trim(UPDATE_PID)
	if pid and pid:match("^%d+$") and nixio.fs.access("/proc/" .. pid) then
		return true
	end
	return false
end

-- Angka besar (byte) disimpan sebagai string desimal utuh: format
-- "%.0f" aman untuk nilai < 2^53 dan tidak kena overflow %d 32-bit.
local function fmt_num(n)
	return string.format("%.0f", tonumber(n) or 0)
end

local function today_str()
	return os.date("%Y-%m-%d")
end

-- ---------- UCI ----------

local function new_cursor()
	return luci.model.uci.cursor()
end

-- Keberadaan section TIDAK bisa dicek dengan uci:get 2 argumen
-- (tanpa opsi ia tidak mengembalikan isi section di libuci asli);
-- pakai get_all. Pelajaran dari bug urungkan 0.1.5: delete_section
-- yang digerbangi get 2 argumen tidak pernah benar-benar menghapus.
local function section_exists(uci, name)
	if not name then return false end
	return uci:get_all(CONFIG, name) ~= nil
end

local function get_settings(uci)
	if not section_exists(uci, "settings") then
		uci:section(CONFIG, "settings", "settings")
		for k, v in pairs(DEFAULTS) do uci:set(CONFIG, "settings", k, v) end
		uci:commit(CONFIG)
	end
	local s = {}
	for _, k in ipairs(SETTINGS_KEYS) do
		s[k] = uci:get(CONFIG, "settings", k) or DEFAULTS[k]
	end
	return s
end

local function period_from_section(uci, name)
	local start = uci:get(CONFIG, name, "start")
	if not start then return nil end
	return {
		start = start,
		days = tonumber(uci:get(CONFIG, name, "days")) or 28,
	}
end

local function write_period(uci, name, p)
	uci:section(CONFIG, "period", name)
	uci:set(CONFIG, name, "start", p.start)
	uci:set(CONFIG, name, "days", fmt_num(p.days))
end

local function delete_section(uci, name)
	if section_exists(uci, name) then
		uci:delete(CONFIG, name)
		return true
	end
	return false
end

-- ---------- sumber API Sunset ----------

local function api_state_path()
	return os.getenv("BK_API_STATE") or "/etc/boundlesskuota-api.json"
end

local function load_json_file(path)
	local raw = read_file(path)
	if not raw or raw == "" then return nil end
	local t = luci.jsonc.parse(raw)
	if type(t) ~= "table" then return nil end
	return t
end

local function save_json_file(path, tbl)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(luci.jsonc.stringify(tbl))
	f:close()
	return true
end

-- Config backend dipinjam dari app Sunset (satu-satunya pemilik
-- secret): uci sunset.settings.api_url + .secret.
local function sunset_config()
	local c = new_cursor()
	local url = c:get("sunset", "settings", "api_url")
	local secret = c:get("sunset", "settings", "secret")
	if url then url = (url:gsub("/+$", "")) end
	return url, secret
end

local function fetch_api_json(url, secret)
	local out = luci.sys.exec(string.format(
		"curl -fsSL --connect-timeout 6 --max-time 25 -H %s %s 2>/dev/null",
		luci.util.shellquote("x-luci-secret: " .. secret),
		luci.util.shellquote(url)))
	if not out or out == "" then return nil end
	local t = luci.jsonc.parse(out)
	if type(t) ~= "table" then return nil end
	return t
end

-- Siapkan data API untuk periode aktif: ambil welcome + history
-- SEGAR (tanpa cache) dan perbarui keadaan tersimpan. Mengembalikan
-- (info, state, expiry). Bila API tidak terjangkau, state adalah
-- keadaan tersimpan terakhir (atau nil) dan info.stale menandainya;
-- angka yang ditampilkan pemanggil berasal dari state itu apa
-- adanya. State milik periode lain diabaikan (periode baru
-- menyemai keadaannya sendiri).
local function api_prepare(active)
	local info = { configured = false, active = false, stale = false }
	local expiry = core.add_days(active.start, active.days)
	local st = load_json_file(api_state_path())
	if st and st.period_start ~= active.start then st = nil end

	local base_url, secret = sunset_config()
	if not base_url or base_url == "" or not secret or secret == "" then
		return info, st, expiry
	end
	info.configured = true

	local welcome = fetch_api_json(base_url .. "/api/luci/welcome", secret)
	if not welcome or welcome.ok ~= true or type(welcome.quotas) ~= "table" then
		info.error = "API Sunset tidak terjangkau."
		info.stale = st ~= nil
		return info, st, expiry
	end
	local history = fetch_api_json(base_url .. "/api/luci/history", secret)

	local live, remaining = {}, 0
	for _, q in ipairs(welcome.quotas) do
		if not q.unlimited and tonumber(q.total_bytes) and tonumber(q.remaining_bytes) then
			live[#live + 1] = {
				key = core.benefit_key(q.name, q.expired_at),
				total = tonumber(q.total_bytes),
				remaining = tonumber(q.remaining_bytes),
			}
			remaining = remaining + tonumber(q.remaining_bytes)
		end
	end

	if not st then
		st = core.api_seed(live, 0)
		st.period_start = active.start
		st.number = welcome.number
		info.seeded = true
	elseif tostring(st.number) ~= tostring(welcome.number) then
		core.api_reseed(st, live)
		st.number = welcome.number
		st.txs = {}
		info.number_changed = true
	else
		core.api_update(st, live)
	end
	if history and history.ok == true and type(history.transactions) == "table" then
		info.added_tx = core.api_merge_tx(st, history.transactions)
		info.history_ok = true
	end
	local today = today_str()
	st.cum = st.cum or {}
	st.cum[today] = core.api_used(st)
	st.last_fetch = os.time()
	st.last_remaining = remaining
	save_json_file(api_state_path(), st)

	info.active = true
	info.number = welcome.number
	info.last_fetch = st.last_fetch
	return info, st, expiry
end

-- Rincian harian periode: pemakaian dari kumulatif keadaan +
-- biaya riil dari pembelian tercatat pada tanggalnya. Mengembalikan
-- (rows, expired). Setiap baris: date, bytes, cum_bytes, cost,
-- cum_cost, price_per_gb (kumulatif s/d hari itu).
local function build_daily(st, active, today, expiry)
	local expired = today >= expiry
	local end_excl = expired and expiry or core.add_days(today, 1)
	local by_day = st and core.purchases_by_day(st, active.start, end_excl) or {}
	local rows, seen = {}, {}
	if st then
		for _, d in ipairs(core.api_days(st, active.start, today)) do
			if d.date >= active.start and d.date < end_excl then
				rows[#rows + 1] = { date = d.date, bytes = d.bytes }
				seen[d.date] = true
			end
		end
	end
	for date in pairs(by_day) do
		if not seen[date] then rows[#rows + 1] = { date = date, bytes = 0 } end
	end
	table.sort(rows, function(a, b) return a.date < b.date end)
	local cum_bytes, cum_cost = 0, 0
	for _, r in ipairs(rows) do
		cum_bytes = cum_bytes + r.bytes
		r.cost = by_day[r.date] or 0
		cum_cost = cum_cost + r.cost
		r.cum_bytes = cum_bytes
		r.cum_cost = cum_cost
		r.price_per_gb = cum_bytes > 0 and (cum_cost / (cum_bytes / core.GB)) or 0
	end
	return rows, expired, end_excl
end

-- ---------- status ----------

local function collect_history(uci)
	local list = {}
	uci:foreach(CONFIG, "snapshot", function(s)
		local item = {
			id = s[".name"],
			start = s.start, end_date = s.end_date,
			duration_days = tonumber(s.duration_days) or 0,
			used_bytes = tonumber(s.used_bytes) or 0,
			paid = tonumber(s.paid) or 0,
			purchases_count = tonumber(s.purchases_count) or 0,
		}
		if s.purchases then
			local p = luci.jsonc.parse(s.purchases)
			if type(p) == "table" then item.purchases = p end
		end
		list[#list + 1] = item
	end)
	table.sort(list, function(a, b) return (a.start or "") > (b.start or "") end)
	return list
end

function action_status()
	local uci = new_cursor()
	local settings = get_settings(uci)
	local active = period_from_section(uci, "active")
	local today = today_str()

	local computed, api = nil, nil
	if active then
		local info, st, expiry = api_prepare(active)
		api = info
		local daily, expired, end_excl = build_daily(st, active, today, expiry)
		local used = 0
		if st then
			used = expired and core.used_until(st, expiry)
				or core.api_used(st)
		end
		local purch = st and core.api_purchases(st, active.start, end_excl)
			or { list = {}, total = 0, count = 0 }
		local today_bytes = 0
		for _, r in ipairs(daily) do
			if r.date == today then today_bytes = r.bytes end
		end
		local day_number = (core.day_diff(active.start, today) or 0) + 1
		if day_number < 1 then day_number = 1 end
		if day_number > active.days then day_number = active.days end
		local est = st and core.unrecorded_estimate(st, purch.list) or nil
		computed = {
			expiry = expiry,
			expired = expired,
			day_number = day_number,
			days_total = active.days,
			used_bytes = used,
			remaining_bytes = st and core.usable_remaining(st) or nil,
			remaining_all_bytes = st and st.last_remaining or nil,
			today_bytes = today_bytes,
			daily = daily,
			purchases_total = purch.total,
			purchases_count = purch.count,
			price_per_gb = used > 0 and (purch.total / (used / core.GB)) or 0,
			unrecorded_bytes = st and core.unrecorded_gap(st, purch.list) or 0,
			unrecorded_est_cost = est and est.cost or 0,
			unrecorded_est_buckets = est and est.buckets or 0,
			unrecorded_est_unit = est and est.unit or 0,
		}
		api.purchases = purch.list
		api.purchases_total = purch.total
		api.purchases_count = purch.count
		api.buckets = st and core.bucket_list(st) or {}
		api.last_fetch = st and st.last_fetch or nil
	end

	local history = collect_history(uci)
	local totals = { used_bytes = 0, paid = 0, duration_days = 0 }
	for _, h in ipairs(history) do
		totals.used_bytes = totals.used_bytes + h.used_bytes
		totals.paid = totals.paid + h.paid
		totals.duration_days = totals.duration_days + h.duration_days
	end
	if computed then
		totals.used_bytes = totals.used_bytes + computed.used_bytes
		totals.paid = totals.paid + computed.purchases_total
		totals.duration_days = totals.duration_days + computed.day_number
	end

	write_json({
		ok = true,
		version = installed_version(),
		today = today,
		settings = settings,
		active = active and {
			start = active.start, days = active.days,
			computed = computed,
		} or nil,
		history = history,
		totals = totals,
		can_undo = section_exists(uci, "lastclose"),
		health = {
			has_active = active ~= nil,
			api_configured = api and api.configured or false,
			api_active = api and api.active or false,
			api_stale = api and api.stale or false,
			expired = computed and computed.expired or false,
		},
		api = api,
	})
end

-- ---------- aksi periode ----------

function action_start()
	if not require_post() then return end
	local date = luci.http.formvalue("date") or ""
	local days_in = tonumber(luci.http.formvalue("days"))
	if days_in ~= nil then
		if days_in < 1 or days_in > 366 or days_in ~= math.floor(days_in) then
			return write_json({ ok = false, error = "Masa aktif tidak sah (1-366 hari)." }, 400)
		end
	end
	if not core.valid_date(date) then
		return write_json({ ok = false, error = "Tanggal mulai tidak sah." }, 400)
	end
	if date > today_str() then
		return write_json({ ok = false, error = "Tanggal mulai tidak boleh di masa depan." }, 400)
	end

	local uci = new_cursor()
	local settings = get_settings(uci)
	local active = period_from_section(uci, "active")

	if active then
		if date <= active.start then
			return write_json({ ok = false, error = "Tanggal mulai harus sesudah tanggal mulai periode berjalan." }, 400)
		end
		-- Tutup periode berjalan sebagai snapshot. Akhir efektif
		-- adalah yang lebih dulu: tanggal mulai baru atau
		-- kedaluwarsa resmi.
		local expiry = core.add_days(active.start, active.days)
		local end_excl = date < expiry and date or expiry
		if end_excl <= active.start then
			return write_json({ ok = false, error = "Periode berjalan tidak punya hari untuk ditutup." }, 400)
		end
		local _, st = api_prepare(active)
		local snap
		if st then
			-- Terpakai snapshot: bila jendela berakhir hari ini,
			-- seluruh pemakaian sampai saat penutupan adalah
			-- milik periode lama (periode baru mengukur dari
			-- titik semai sesudahnya); bila jendela berakhir di
			-- masa lalu (kedaluwarsa/backdate), pakai kumulatif
			-- tercatat sampai akhir jendela.
			local used_bytes
			if end_excl >= today_str() then
				used_bytes = core.api_used(st)
			else
				used_bytes = core.used_until(st, end_excl)
			end
			snap = core.period_snapshot(st, active.start, end_excl, used_bytes)
		else
			snap = {
				start = active.start, end_date = end_excl,
				duration_days = core.day_diff(active.start, end_excl) or 0,
				used_bytes = 0, paid = 0, purchases_count = 0, purchases = {},
			}
		end
		local sid = uci:section(CONFIG, "snapshot")
		uci:set(CONFIG, sid, "start", snap.start)
		uci:set(CONFIG, sid, "end_date", snap.end_date)
		uci:set(CONFIG, sid, "duration_days", fmt_num(snap.duration_days))
		uci:set(CONFIG, sid, "used_bytes", fmt_num(snap.used_bytes))
		uci:set(CONFIG, sid, "paid", fmt_num(snap.paid))
		uci:set(CONFIG, sid, "purchases_count", fmt_num(snap.purchases_count))
		uci:set(CONFIG, sid, "purchases", luci.jsonc.stringify(snap.purchases))

		-- Simpan keadaan aktif lama untuk Urungkan.
		delete_section(uci, "lastclose")
		uci:section(CONFIG, "lastclose", "lastclose")
		for _, k in ipairs(PERIOD_KEYS) do
			local v = uci:get(CONFIG, "active", k)
			if v ~= nil then uci:set(CONFIG, "lastclose", k, v) end
		end
		uci:set(CONFIG, "lastclose", "snapshot_id", sid)

		-- Keadaan API periode lama disimpan untuk Urungkan.
		-- Periode baru menyemai keadaannya sendiri, TAPI koreksi
		-- harga riil dipertahankan: transaksi bertanggal mulai
		-- periode baru (mis. dasar yang baru saja dibeli) masuk
		-- jendela periode baru, dan override-nya harus tetap
		-- berlaku tanpa diisi ulang.
		local api_path = api_state_path()
		local st_raw = read_file(api_path)
		if st_raw then
			local f = io.open(api_path .. ".lastclose", "w")
			if f then f:write(st_raw) f:close() end
			os.remove(api_path)
		end
		if st and type(st.price_overrides) == "table"
			and next(st.price_overrides) ~= nil then
			save_json_file(api_path, {
				period_start = date,
				price_overrides = st.price_overrides,
			})
		end
	else
		-- Periode pertama: berkas keadaan sisa (dari reset/impor
		-- lama) tidak berlaku untuk periode ini.
		os.remove(api_state_path())
	end

	delete_section(uci, "active")
	write_period(uci, "active", {
		start = date,
		days = days_in or tonumber(settings.days) or 28,
	})
	uci:commit(CONFIG)
	write_json({ ok = true })
end

function action_undo()
	if not require_post() then return end
	local uci = new_cursor()
	if not section_exists(uci, "lastclose") then
		return write_json({ ok = false, error = "Tidak ada periode yang bisa diurungkan." }, 400)
	end
	local sid = uci:get(CONFIG, "lastclose", "snapshot_id")
	local p = {}
	for _, k in ipairs(PERIOD_KEYS) do
		p[k] = uci:get(CONFIG, "lastclose", k)
	end
	if sid then delete_section(uci, sid) end
	-- Sapu-bersih cadangan: snapshot prematur adalah satu-satunya
	-- snapshot yang tanggal mulainya SAMA dengan tanggal mulai
	-- periode yang dipulihkan (snapshot sah selalu mulai lebih awal).
	if p.start then
		local doomed = {}
		uci:foreach(CONFIG, "snapshot", function(s)
			if s.start == p.start then doomed[#doomed + 1] = s[".name"] end
		end)
		for _, n in ipairs(doomed) do uci:delete(CONFIG, n) end
	end
	delete_section(uci, "active")
	uci:section(CONFIG, "period", "active")
	for k, v in pairs(p) do
		if v ~= nil then uci:set(CONFIG, "active", k, v) end
	end
	delete_section(uci, "lastclose")
	-- Pulihkan keadaan API periode yang diurungkan (bila ada);
	-- tanpa cadangan, keadaan API periode prematur dibuang.
	local api_path = api_state_path()
	local lc_raw = read_file(api_path .. ".lastclose")
	if lc_raw then
		local f = io.open(api_path, "w")
		if f then f:write(lc_raw) f:close() end
		os.remove(api_path .. ".lastclose")
	else
		os.remove(api_path)
	end
	uci:commit(CONFIG)
	write_json({ ok = true })
end

-- Koreksi harga riil satu transaksi tercatat (0.3.2): riwayat XL
-- mencatat harga katalog, sedangkan pengguna bisa membayar lain
-- (mis. Xtra Combo Plus katalog Rp35.000 dibayar Rp30.000).
-- Override disimpan di keadaan API per kunci transaksi; price
-- kosong menghapus override. Total Pembelian Tercatat sesudahnya
-- = pengeluaran sebenarnya.
function action_txprice()
	if not require_post() then return end
	local key = luci.http.formvalue("key")
	local price_txt = luci.http.formvalue("price")
	local st = load_json_file(api_state_path())
	if not st or not key or type(st.txs) ~= "table" or st.txs[key] == nil then
		return write_json({ ok = false, error = "Transaksi tidak ditemukan." }, 400)
	end
	st.price_overrides = type(st.price_overrides) == "table" and st.price_overrides or {}
	if price_txt == nil or price_txt == "" then
		st.price_overrides[key] = nil
	else
		local p = tonumber(price_txt)
		if not p or p < 0 or p > 100000000 or p ~= math.floor(p) then
			return write_json({ ok = false, error = "Harga tidak sah." }, 400)
		end
		st.price_overrides[key] = p
	end
	save_json_file(api_state_path(), st)
	return write_json({ ok = true })
end

function action_settings()
	if not require_post() then return end
	local days = tonumber(luci.http.formvalue("days"))
	if not days or days < 1 or days > 366 or days ~= math.floor(days) then
		return write_json({ ok = false, error = "Masa aktif tidak sah (1-366 hari)." }, 400)
	end
	local uci = new_cursor()
	get_settings(uci)
	uci:set(CONFIG, "settings", "days", fmt_num(days))
	uci:commit(CONFIG)
	write_json({ ok = true })
end

-- ---------- ekspor / impor cadangan ----------

local function section_map(uci, name, keys)
	if not section_exists(uci, name) then return nil end
	local m = {}
	for _, k in ipairs(keys) do
		local v = uci:get(CONFIG, name, k)
		if v ~= nil then m[k] = v end
	end
	return m
end

function action_export()
	local uci = new_cursor()
	local snaps = {}
	uci:foreach(CONFIG, "snapshot", function(s)
		local m = { id = s[".name"] }
		for _, k in ipairs(SNAPSHOT_KEYS) do
			if s[k] ~= nil then m[k] = s[k] end
		end
		snaps[#snaps + 1] = m
	end)
	local data = {
		app = "boundless-kuota",
		format = 1,
		exported = os.date("%Y-%m-%d %H:%M:%S"),
		version = installed_version(),
		settings = section_map(uci, "settings", SETTINGS_KEYS),
		active = section_map(uci, "active", PERIOD_KEYS),
		history = snaps,
		api_state = load_json_file(api_state_path()),
	}
	luci.http.header("Content-Disposition",
		'attachment; filename="boundless-kuota-backup.json"')
	luci.http.prepare_content("application/json")
	luci.http.write(luci.jsonc.stringify(data))
end

function action_import()
	if not require_post() then return end
	local raw = luci.http.formvalue("data") or ""
	local data = luci.jsonc.parse(raw)
	if type(data) ~= "table" or data.app ~= "boundless-kuota" then
		return write_json({ ok = false, error = "File cadangan tidak sah untuk app ini." }, 400)
	end
	local uci = new_cursor()
	-- Hapus keadaan lama.
	local doomed = {}
	uci:foreach(CONFIG, "snapshot", function(s) doomed[#doomed + 1] = s[".name"] end)
	uci:foreach(CONFIG, "period", function(s) doomed[#doomed + 1] = s[".name"] end)
	uci:foreach(CONFIG, "lastclose", function(s) doomed[#doomed + 1] = s[".name"] end)
	for _, n in ipairs(doomed) do uci:delete(CONFIG, n) end

	if type(data.settings) == "table" then
		if not section_exists(uci, "settings") then
			uci:section(CONFIG, "settings", "settings")
		end
		for _, k in ipairs(SETTINGS_KEYS) do
			if data.settings[k] ~= nil then
				uci:set(CONFIG, "settings", k, tostring(data.settings[k]))
			end
		end
	end
	if type(data.active) == "table" and data.active.start then
		uci:section(CONFIG, "period", "active")
		for _, k in ipairs(PERIOD_KEYS) do
			if data.active[k] ~= nil then
				uci:set(CONFIG, "active", k, tostring(data.active[k]))
			end
		end
	end
	if type(data.history) == "table" then
		for _, s in ipairs(data.history) do
			if type(s) == "table" and s.start then
				local sid = uci:section(CONFIG, "snapshot")
				for _, k in ipairs(SNAPSHOT_KEYS) do
					if s[k] ~= nil then uci:set(CONFIG, sid, k, tostring(s[k])) end
				end
			end
		end
	end
	-- Keadaan API: pulihkan dari cadangan yang memuatnya; cadangan
	-- lama (tanpa api_state) mengosongkannya agar tidak basi.
	if type(data.api_state) == "table" then
		save_json_file(api_state_path(), data.api_state)
	else
		os.remove(api_state_path())
	end
	os.remove(api_state_path() .. ".lastclose")
	uci:commit(CONFIG)
	write_json({ ok = true })
end

-- Reset data app: hapus semua snapshot riwayat + periode aktif +
-- cadangan urungkan + keadaan API. Pengaturan dipertahankan.
function action_reset()
	if not require_post() then return end
	local uci = new_cursor()
	local doomed = {}
	uci:foreach(CONFIG, "snapshot", function(s) doomed[#doomed + 1] = s[".name"] end)
	for _, n in ipairs(doomed) do uci:delete(CONFIG, n) end
	delete_section(uci, "active")
	delete_section(uci, "lastclose")
	os.remove(api_state_path())
	os.remove(api_state_path() .. ".lastclose")
	uci:commit(CONFIG)
	return write_json({ ok = true })
end

-- ---------- Versi & Update (pola luci-app-boundless-tools) ----------

function action_version()
	write_json({ ok = true, installed = installed_version() })
end

function action_check()
	local installed = installed_version()
	local tag = latest_tag()
	if not tag then
		return write_json({ ok = false,
			error = "Gagal menghubungi GitHub. Cek koneksi internet STB.",
			installed = installed }, 502)
	end
	local latest = tag:gsub("^v", "")
	write_json({
		ok = true,
		installed = installed,
		latest = tag,
		update_available = latest ~= installed,
	})
end

function action_update()
	if not require_post() then return end
	if update_running() then
		return write_json({ ok = false, error = "Update sedang berjalan. Tunggu sampai selesai." }, 409)
	end
	local tag = latest_tag()
	if not tag then
		return write_json({ ok = false,
			error = "Gagal menghubungi GitHub. Cek koneksi internet STB." }, 502)
	end
	local script_url = REPO_RAW .. "/" .. tag .. "/online-install.sh"

	luci.sys.call(string.format("rm -f %s %s %s",
		luci.util.shellquote(UPDATE_LOG),
		luci.util.shellquote(UPDATE_RC),
		luci.util.shellquote(UPDATE_PID)))

	local body = string.format([[
echo "[boundless-kuota] Mengunduh online-install.sh rilis %s ..."
if curl -fsSL --connect-timeout 10 --max-time 60 %s -o %s 2>/dev/null || wget -q --timeout=60 %s -O %s 2>/dev/null; then
    sh %s
else
    echo "[boundless-kuota] Gagal mengunduh online-install.sh dari GitHub"
    false
fi]],
		tag,
		luci.util.shellquote(script_url),
		luci.util.shellquote(UPDATE_SCRIPT),
		luci.util.shellquote(script_url),
		luci.util.shellquote(UPDATE_SCRIPT),
		luci.util.shellquote(UPDATE_SCRIPT))

	local wrapper = string.format("echo $$ > %s\n%s\necho $? > %s\nrm -f %s",
		UPDATE_PID, body, UPDATE_RC, UPDATE_PID)

	local prefix = ""
	if luci.sys.call("command -v setsid >/dev/null 2>&1") == 0 then
		prefix = "setsid "
	elseif luci.sys.call("command -v nohup >/dev/null 2>&1") == 0 then
		prefix = "nohup "
	end
	luci.sys.call(string.format("%ssh -c %s </dev/null >%s 2>&1 &",
		prefix, luci.util.shellquote(wrapper),
		luci.util.shellquote(UPDATE_LOG)))

	write_json({ ok = true, started = true, latest = tag })
end

function action_updatelog()
	local rc = read_trim(UPDATE_RC)
	local code
	if rc and rc:match("^%-?%d+$") then code = tonumber(rc) end
	write_json({
		ok = true,
		log = read_tail(UPDATE_LOG, 4000),
		rc = code,
		running = update_running(),
	})
end
