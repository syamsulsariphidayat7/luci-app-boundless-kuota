module("luci.controller.boundlesskuota", package.seeall)

-- luci-app-boundless-kuota: monitoring kuota internet GSM dari vnStat.
-- Controller melayani dashboard (Services -> Monitoring Kuota) dan
-- endpoint JSON-nya:
--   GET  status   -> seluruh keadaan dashboard (periode, riwayat, sehat)
--   POST start    -> tutup periode berjalan (snapshot) + mulai baru
--   POST undo     -> urungkan periode baru terakhir (pulihkan sebelumnya)
--   POST correct  -> koreksi ± blok terbeli periode berjalan
--   POST settings -> simpan skema/interface untuk periode berikutnya
--   POST setup    -> aktifkan monitoring wwan0 di config vnStat
--   GET  export   -> unduh cadangan JSON (riwayat + periode + pengaturan)
--   POST import   -> pulihkan cadangan JSON
--   GET  version / check, POST update, GET updatelog (Versi & Update)
-- Perhitungan murni ada di luci.model.boundlesskuota_core. App ini
-- tidak pernah menulis ke database vnStat; vnStat hanya dibaca.
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
	entry({"admin", "services", "boundlesskuota", "correct"},
		post("action_correct")).leaf = true
	entry({"admin", "services", "boundlesskuota", "settings"},
		post("action_settings")).leaf = true
	entry({"admin", "services", "boundlesskuota", "setup"},
		post("action_setup")).leaf = true
	entry({"admin", "services", "boundlesskuota", "export"},
		call("action_export")).leaf = true
	entry({"admin", "services", "boundlesskuota", "import"},
		post("action_import")).leaf = true
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

local SETTINGS_KEYS = { "mode", "base", "block_gb", "block_rp", "days",
	"direct_rp", "direct_gb", "next_iface", "setup_done", "initialized" }
local PERIOD_KEYS   = { "start", "iface", "mode", "base", "block_gb",
	"block_rp", "days", "direct_rp", "direct_gb", "opening_blocks",
	"correction", "auto" }
local SNAPSHOT_KEYS = { "start", "end_date", "duration_days", "used_bytes",
	"dl_bytes", "ul_bytes", "blocks", "purchased_bytes", "paid",
	"hangus_bytes", "iface", "mode", "base", "block_gb", "block_rp",
	"days", "direct_rp", "direct_gb", "opening_blocks", "correction" }

local DEFAULTS = {
	mode = "blok", base = "30000", block_gb = "10", block_rp = "3000",
	days = "28", direct_rp = "50000", direct_gb = "0",
	next_iface = "wwan0", setup_done = "0", initialized = "0",
}

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

local function get_settings(uci)
	if not uci:get(CONFIG, "settings") then
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
	local p = {}
	local any = false
	for _, k in ipairs(PERIOD_KEYS) do
		local v = uci:get(CONFIG, name, k)
		if v ~= nil then any = true end
		p[k] = v
	end
	if not any then return nil end
	return {
		start = p.start,
		iface = p.iface or "br-lan",
		mode = p.mode or "blok",
		base = tonumber(p.base) or 0,
		block_gb = tonumber(p.block_gb) or 10,
		block_rp = tonumber(p.block_rp) or 0,
		days = tonumber(p.days) or 28,
		direct_rp = tonumber(p.direct_rp) or 0,
		direct_gb = tonumber(p.direct_gb) or 0,
		opening_blocks = tonumber(p.opening_blocks) or 0,
		correction = tonumber(p.correction) or 0,
		auto = p.auto or "0",
	}
end

local function write_period(uci, name, p)
	uci:section(CONFIG, "period", name)
	local vals = {
		start = p.start, iface = p.iface, mode = p.mode,
		base = fmt_num(p.base), block_gb = fmt_num(p.block_gb),
		block_rp = fmt_num(p.block_rp), days = fmt_num(p.days),
		direct_rp = fmt_num(p.direct_rp), direct_gb = fmt_num(p.direct_gb),
		opening_blocks = fmt_num(p.opening_blocks),
		correction = fmt_num(p.correction), auto = p.auto or "0",
	}
	for k, v in pairs(vals) do uci:set(CONFIG, name, k, v) end
end

local function delete_section(uci, name)
	if name and uci:get(CONFIG, name) then
		uci:delete(CONFIG, name)
		return true
	end
	return false
end

-- ---------- vnStat ----------

local function vnstat_data()
	local out = luci.sys.exec("vnstat --json 2>/dev/null")
	if not out or out == "" then return nil end
	local data = luci.jsonc.parse(out)
	if not data or type(data.interfaces) ~= "table" then return nil end
	return data
end

local function find_iface(vdata, name)
	if not vdata then return nil end
	for _, i in ipairs(vdata.interfaces) do
		if i.name == name then return i end
	end
	return nil
end

local function iface_days(vdata, name)
	local i = find_iface(vdata, name)
	if not i or not i.traffic then return {} end
	return core.collect_days(i.traffic.day, name == "br-lan")
end

local function iface_updated(vdata, name)
	local i = find_iface(vdata, name)
	if not i or not i.updated or not i.updated.date then return nil end
	local d, t = i.updated.date, i.updated.time or {}
	return string.format("%04d-%02d-%02d %02d:%02d",
		tonumber(d.year) or 0, tonumber(d.month) or 0, tonumber(d.day) or 0,
		tonumber(t.hour) or 0, tonumber(t.minute) or 0)
end

local function vnstat_config_ifaces(uci)
	local sec = uci:get_first("vnstat", "vnstat")
	if not sec then return {} end
	local v = uci:get("vnstat", sec, "interface")
	if type(v) == "table" then return v end
	if type(v) == "string" and v ~= "" then return { v } end
	return {}
end

local function list_contains(list, name)
	for _, v in ipairs(list) do if v == name then return true end end
	return false
end

-- Keadaan awal PnP: periode pertama otomatis memakai interface yang
-- sudah punya data (br-lan lebih dulu), sekaligus skema bawaan.
local function ensure_state(uci, vdata)
	local settings = get_settings(uci)
	if settings.initialized == "1" then return settings end
	if period_from_section(uci, "active") then
		uci:set(CONFIG, "settings", "initialized", "1")
		uci:commit(CONFIG)
		settings.initialized = "1"
		return settings
	end
	local chosen, start = nil, today_str()
	if vdata then
		local candidates = {}
		for _, i in ipairs(vdata.interfaces) do
			local d = iface_days(vdata, i.name)
			if #d > 0 then candidates[#candidates + 1] = { name = i.name, first = d[1].date } end
		end
		table.sort(candidates, function(a, b)
			if a.name == "br-lan" then return true end
			if b.name == "br-lan" then return false end
			return a.first < b.first
		end)
		if candidates[1] then
			chosen, start = candidates[1].name, candidates[1].first
		end
	end
	local p = {
		start = start, iface = chosen or "wwan0",
		mode = settings.mode, base = tonumber(settings.base) or 30000,
		block_gb = tonumber(settings.block_gb) or 10,
		block_rp = tonumber(settings.block_rp) or 3000,
		days = tonumber(settings.days) or 28,
		direct_rp = tonumber(settings.direct_rp) or 0,
		direct_gb = tonumber(settings.direct_gb) or 0,
		opening_blocks = 0, correction = 0, auto = "1",
	}
	write_period(uci, "active", p)
	uci:set(CONFIG, "settings", "initialized", "1")
	uci:commit(CONFIG)
	settings.initialized = "1"
	return settings
end

-- ---------- status ----------

local function collect_history(uci)
	local list = {}
	uci:foreach(CONFIG, "snapshot", function(s)
		list[#list + 1] = {
			id = s[".name"],
			start = s.start, end_date = s.end_date,
			duration_days = tonumber(s.duration_days) or 0,
			used_bytes = tonumber(s.used_bytes) or 0,
			dl_bytes = tonumber(s.dl_bytes) or 0,
			ul_bytes = tonumber(s.ul_bytes) or 0,
			blocks = tonumber(s.blocks) or 0,
			purchased_bytes = tonumber(s.purchased_bytes),
			paid = tonumber(s.paid) or 0,
			hangus_bytes = tonumber(s.hangus_bytes) or 0,
			iface = s.iface, mode = s.mode,
		}
	end)
	table.sort(list, function(a, b) return (a.start or "") > (b.start or "") end)
	return list
end

function action_status()
	local uci = new_cursor()
	local vdata = vnstat_data()
	local settings = ensure_state(uci, vdata)
	local active = period_from_section(uci, "active")

	local computed = nil
	local active_days = {}
	if active then
		active_days = iface_days(vdata, active.iface)
		computed = core.compute(active_days, active, today_str(), os.time())
	end

	local history = collect_history(uci)
	local totals = { used_bytes = 0, paid = 0, duration_days = 0, hangus_bytes = 0 }
	for _, h in ipairs(history) do
		totals.used_bytes = totals.used_bytes + h.used_bytes
		totals.paid = totals.paid + h.paid
		totals.duration_days = totals.duration_days + h.duration_days
		totals.hangus_bytes = totals.hangus_bytes + h.hangus_bytes
	end
	if computed then
		totals.used_bytes = totals.used_bytes + computed.used_bytes
		totals.paid = totals.paid + computed.paid
		totals.duration_days = totals.duration_days + computed.day_number
	end

	local cfg_ifaces = vnstat_config_ifaces(uci)
	local health = {
		vnstat_ok = vdata ~= nil,
		wwan_monitored = list_contains(cfg_ifaces, "wwan0"),
		config_ifaces = cfg_ifaces,
		has_active = active ~= nil,
	}
	if active then
		health.active_iface = active.iface
		health.active_monitored = find_iface(vdata, active.iface) ~= nil
		health.updated = iface_updated(vdata, active.iface)
		if computed then
			health.complete = computed.complete
			health.missing_days = computed.missing_days
			health.expired = computed.expired
		end
	end

	write_json({
		ok = true,
		version = installed_version(),
		today = today_str(),
		settings = settings,
		active = active and {
			start = active.start, iface = active.iface, mode = active.mode,
			base = active.base, block_gb = active.block_gb,
			block_rp = active.block_rp, days = active.days,
			direct_rp = active.direct_rp, direct_gb = active.direct_gb,
			opening_blocks = active.opening_blocks,
			correction = active.correction, auto = active.auto,
			computed = computed,
		} or nil,
		history = history,
		totals = totals,
		can_undo = uci:get(CONFIG, "lastclose") ~= nil,
		health = health,
	})
end

-- ---------- aksi periode ----------

function action_start()
	if not require_post() then return end
	local date = luci.http.formvalue("date") or ""
	local opening = tonumber(luci.http.formvalue("opening_blocks")) or 0
	if opening < 0 then opening = 0 end
	if opening > 10000 then opening = 10000 end
	if not core.valid_date(date) then
		return write_json({ ok = false, error = "Tanggal mulai tidak sah." }, 400)
	end
	if date > today_str() then
		return write_json({ ok = false, error = "Tanggal mulai tidak boleh di masa depan." }, 400)
	end

	local uci = new_cursor()
	local vdata = vnstat_data()
	local settings = ensure_state(uci, vdata)
	local active = period_from_section(uci, "active")
	if not active then
		return write_json({ ok = false, error = "Belum ada periode aktif." }, 400)
	end
	if date <= active.start then
		return write_json({ ok = false, error = "Tanggal mulai harus sesudah tanggal mulai periode berjalan." }, 400)
	end

	-- Tutup periode berjalan sebagai snapshot. Akhir efektif adalah
	-- yang lebih dulu: tanggal mulai baru atau kedaluwarsa resmi.
	local expiry = core.add_days(active.start, active.days)
	local end_excl = date < expiry and date or expiry
	if end_excl <= active.start then
		return write_json({ ok = false, error = "Periode berjalan tidak punya hari untuk ditutup." }, 400)
	end
	local days = iface_days(vdata, active.iface)
	local snap = core.snapshot(days, active, end_excl)

	local sid = uci:section(CONFIG, "snapshot")
	uci:set(CONFIG, sid, "start", snap.start)
	uci:set(CONFIG, sid, "end_date", snap.end_date)
	uci:set(CONFIG, sid, "duration_days", fmt_num(snap.duration_days))
	uci:set(CONFIG, sid, "used_bytes", fmt_num(snap.used_bytes))
	uci:set(CONFIG, sid, "dl_bytes", fmt_num(snap.dl_bytes))
	uci:set(CONFIG, sid, "ul_bytes", fmt_num(snap.ul_bytes))
	uci:set(CONFIG, sid, "blocks", fmt_num(snap.blocks))
	if snap.purchased_bytes ~= nil then
		uci:set(CONFIG, sid, "purchased_bytes", fmt_num(snap.purchased_bytes))
	end
	uci:set(CONFIG, sid, "paid", fmt_num(snap.paid))
	uci:set(CONFIG, sid, "hangus_bytes", fmt_num(snap.hangus_bytes))
	uci:set(CONFIG, sid, "iface", active.iface)
	uci:set(CONFIG, sid, "mode", active.mode)
	uci:set(CONFIG, sid, "base", fmt_num(active.base))
	uci:set(CONFIG, sid, "block_gb", fmt_num(active.block_gb))
	uci:set(CONFIG, sid, "block_rp", fmt_num(active.block_rp))
	uci:set(CONFIG, sid, "days", fmt_num(active.days))
	uci:set(CONFIG, sid, "direct_rp", fmt_num(active.direct_rp))
	uci:set(CONFIG, sid, "direct_gb", fmt_num(active.direct_gb))
	uci:set(CONFIG, sid, "opening_blocks", fmt_num(active.opening_blocks))
	uci:set(CONFIG, sid, "correction", fmt_num(active.correction))

	-- Simpan keadaan aktif lama untuk Urungkan.
	delete_section(uci, "lastclose")
	uci:section(CONFIG, "lastclose", "lastclose")
	for _, k in ipairs(PERIOD_KEYS) do
		local v = uci:get(CONFIG, "active", k)
		if v ~= nil then uci:set(CONFIG, "lastclose", k, v) end
	end
	uci:set(CONFIG, "lastclose", "snapshot_id", sid)

	-- Periode baru memakai skema + interface tersimpan.
	delete_section(uci, "active")
	write_period(uci, "active", {
		start = date, iface = settings.next_iface or "wwan0",
		mode = settings.mode, base = tonumber(settings.base) or 0,
		block_gb = tonumber(settings.block_gb) or 10,
		block_rp = tonumber(settings.block_rp) or 0,
		days = tonumber(settings.days) or 28,
		direct_rp = tonumber(settings.direct_rp) or 0,
		direct_gb = tonumber(settings.direct_gb) or 0,
		opening_blocks = opening, correction = 0, auto = "0",
	})
	uci:commit(CONFIG)
	write_json({ ok = true, snapshot_id = sid })
end

function action_undo()
	if not require_post() then return end
	local uci = new_cursor()
	if not uci:get(CONFIG, "lastclose") then
		return write_json({ ok = false, error = "Tidak ada periode yang bisa diurungkan." }, 400)
	end
	local sid = uci:get(CONFIG, "lastclose", "snapshot_id")
	if sid then delete_section(uci, sid) end
	local p = {}
	for _, k in ipairs(PERIOD_KEYS) do
		p[k] = uci:get(CONFIG, "lastclose", k)
	end
	delete_section(uci, "active")
	uci:section(CONFIG, "period", "active")
	for k, v in pairs(p) do
		if v ~= nil then uci:set(CONFIG, "active", k, v) end
	end
	delete_section(uci, "lastclose")
	uci:commit(CONFIG)
	write_json({ ok = true })
end

function action_correct()
	if not require_post() then return end
	local delta = tonumber(luci.http.formvalue("delta")) or 0
	if delta > 50 then delta = 50 end
	if delta < -50 then delta = -50 end
	local uci = new_cursor()
	local active = period_from_section(uci, "active")
	if not active then
		return write_json({ ok = false, error = "Belum ada periode aktif." }, 400)
	end
	local n = active.correction + delta
	if n > 1000 then n = 1000 end
	if n < -1000 then n = -1000 end
	uci:set(CONFIG, "active", "correction", fmt_num(n))
	uci:commit(CONFIG)
	write_json({ ok = true, correction = n })
end

function action_settings()
	if not require_post() then return end
	local f = function(k) return luci.http.formvalue(k) end
	local mode = f("mode")
	if mode ~= "blok" and mode ~= "langsung" then
		return write_json({ ok = false, error = "Mode skema tidak sah." }, 400)
	end
	local function num(k, min, max)
		local v = tonumber(f(k))
		if v == nil or v < min or v > max then return nil end
		return v
	end
	local base = num("base", 0, 100000000)
	local block_gb = num("block_gb", 1, 100000)
	local block_rp = num("block_rp", 0, 100000000)
	local days = num("days", 1, 366)
	local direct_rp = num("direct_rp", 0, 100000000)
	local direct_gb = num("direct_gb", 0, 1000000)
	local iface = f("next_iface") or ""
	if not (base and block_gb and block_rp and days and direct_rp and direct_gb) then
		return write_json({ ok = false, error = "Ada angka pengaturan yang tidak sah." }, 400)
	end
	if not iface:match("^[%w_%.%-]+$") then
		return write_json({ ok = false, error = "Nama interface tidak sah." }, 400)
	end
	local uci = new_cursor()
	get_settings(uci)
	uci:set(CONFIG, "settings", "mode", mode)
	uci:set(CONFIG, "settings", "base", fmt_num(base))
	uci:set(CONFIG, "settings", "block_gb", fmt_num(block_gb))
	uci:set(CONFIG, "settings", "block_rp", fmt_num(block_rp))
	uci:set(CONFIG, "settings", "days", fmt_num(days))
	uci:set(CONFIG, "settings", "direct_rp", fmt_num(direct_rp))
	uci:set(CONFIG, "settings", "direct_gb", fmt_num(direct_gb))
	uci:set(CONFIG, "settings", "next_iface", iface)
	uci:commit(CONFIG)
	write_json({ ok = true })
end

function action_setup()
	if not require_post() then return end
	local uci = new_cursor()
	local sec = uci:get_first("vnstat", "vnstat")
	if not sec then
		return write_json({ ok = false, error = "Config vnStat tidak ditemukan." }, 500)
	end
	local list = vnstat_config_ifaces(uci)
	if not list_contains(list, "wwan0") then
		uci:add_list("vnstat", sec, "interface", "wwan0")
		uci:commit("vnstat")
		luci.sys.call("/etc/init.d/vnstat restart >/dev/null 2>&1")
	end
	get_settings(uci)
	uci:set(CONFIG, "settings", "setup_done", "1")
	uci:commit(CONFIG)
	write_json({ ok = true })
end

-- ---------- ekspor / impor cadangan ----------

local function section_map(uci, name, keys)
	if not uci:get(CONFIG, name) then return nil end
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
		if not uci:get(CONFIG, "settings") then
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
		uci:set(CONFIG, "settings", "initialized", "1")
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
	uci:commit(CONFIG)
	write_json({ ok = true })
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
