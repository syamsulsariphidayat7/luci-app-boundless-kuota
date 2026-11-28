#!/usr/bin/lua
-- boundlesskuota-snapshot: pemutakhiran berkala keadaan API Sunset
-- milik luci-app-boundless-kuota (dijalankan cron tiap 30 menit).
--
-- Mengambil /api/luci/welcome + /api/luci/history dari backend
-- Sunset dan memperbarui berkas keadaan /etc/boundlesskuota-api.json
-- (peta paket, kumulatif harian, akumulasi transaksi) memakai modul
-- core yang sama dengan controller, supaya tabel harian tetap utuh
-- walau dashboard tidak dibuka berhari-hari.
--
-- Keadaan hanya DIPERBARUI di sini; pembuatan awal (termasuk migrasi
-- offset dari akuntansi vnStat/jangkar) adalah urusan controller
-- saat dashboard pertama kali dimuat. Tanpa berkas keadaan, atau
-- periode sudah berganti, script selesai tanpa melakukan apa-apa.
-- Semua kegagalan ditelan diam-diam: cron tidak boleh berisik, dan
-- dashboard selalu bisa memperbarui keadaan sendiri saat dimuat.

local function shq(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function main()
	local uci = require("luci.model.uci").cursor()
	local jsonc = require("luci.jsonc")
	local core = require("luci.model.boundlesskuota_core")

	local base_url = uci:get("sunset", "settings", "api_url")
	local secret = uci:get("sunset", "settings", "secret")
	if not base_url or base_url == "" or not secret or secret == "" then
		return
	end
	base_url = (base_url:gsub("/+$", ""))

	local period_start = uci:get("boundlesskuota", "active", "start")
	if not period_start then return end

	local state_path = "/etc/boundlesskuota-api.json"
	local f = io.open(state_path, "r")
	if not f then return end
	local raw = f:read("*a")
	f:close()
	local st = jsonc.parse(raw or "")
	if type(st) ~= "table" or st.period_start ~= period_start then return end

	local function fetch(path)
		local cmd = "curl -fsSL --connect-timeout 6 --max-time 25 -H "
			.. shq("x-luci-secret: " .. secret) .. " "
			.. shq(base_url .. path) .. " 2>/dev/null"
		local p = io.popen(cmd)
		if not p then return nil end
		local out = p:read("*a")
		p:close()
		if not out or out == "" then return nil end
		local t = jsonc.parse(out)
		if type(t) ~= "table" then return nil end
		return t
	end

	local welcome = fetch("/api/luci/welcome")
	if not welcome or welcome.ok ~= true or type(welcome.quotas) ~= "table" then
		return
	end
	local live = {}
	for _, q in ipairs(welcome.quotas) do
		if not q.unlimited and tonumber(q.total_bytes) and tonumber(q.remaining_bytes) then
			live[#live + 1] = {
				key = core.benefit_key(q.name, q.expired_at),
				total = tonumber(q.total_bytes),
				remaining = tonumber(q.remaining_bytes),
			}
		end
	end

	if tostring(st.number) ~= tostring(welcome.number) then
		core.api_reseed(st, live)
		st.number = welcome.number
		st.txs = {}
	else
		core.api_update(st, live)
	end

	local history = fetch("/api/luci/history")
	if history and history.ok == true and type(history.transactions) == "table" then
		core.api_merge_tx(st, history.transactions)
	end

	st.cum = st.cum or {}
	st.cum[os.date("%Y-%m-%d")] = core.api_used(st)
	st.last_fetch = os.time()

	local out = io.open(state_path, "w")
	if not out then return end
	out:write(jsonc.stringify(st))
	out:close()
end

pcall(main)
