#!/usr/bin/env python3
"""Simulasi controller boundlesskuota di VM: stub luci.* + UCI di
Python, vnstat --json dari database asli STB. Menguji alur PnP,
setup wwan0, koreksi, mulai/urungkan periode, pengaturan, ekspor/impor.
"""
import json
import os
import sqlite3
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DB = os.path.expanduser("~/workspace/user/files/vnstat.db")

lua = LuaRuntime(unpack_returned_tuples=True)
G = lua.globals()


def py_to_lua(obj):
    if isinstance(obj, dict):
        t = lua.table()
        for k, v in obj.items():
            t[k] = py_to_lua(v)
        return t
    if isinstance(obj, (list, tuple)):
        t = lua.table()
        for i, v in enumerate(obj, 1):
            t[i] = py_to_lua(v)
        return t
    return obj


def lua_to_py(obj):
    if hasattr(obj, "items"):  # tabel Lua
        pairs = list(obj.items())
        if pairs and all(isinstance(k, int) for k, _ in pairs):
            return [lua_to_py(v) for _, v in sorted(pairs)]
        return {str(k): lua_to_py(v) for k, v in pairs}
    return obj


# ---------------- fixture vnstat --json dari DB asli ----------------
con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
day_rows = list(con.execute("SELECT date,rx,tx FROM day ORDER BY date"))
total_bytes = sum(rx + tx for _, rx, tx in day_rows)
today_bytes = sum(rx + tx for d, rx, tx in day_rows if d == "2026-11-12")
days_json = []
for d, rx, tx in day_rows:
    y, m, dd = d.split("-")
    days_json.append({"date": {"year": int(y), "month": int(m), "day": int(dd)},
                      "rx": rx, "tx": tx})
vnstat_json = json.dumps({
    "vnstatversion": "2.12",
    "interfaces": [
        {"name": "br-lan",
         "updated": {"date": {"year": 2026, "month": 11, "day": 12},
                     "time": {"hour": 12, "minute": 45}},
         "traffic": {"day": days_json}},
        {"name": "wwan0",
         "updated": {"date": {"year": 2026, "month": 11, "day": 12},
                     "time": {"hour": 12, "minute": 45}},
         "traffic": {"day": []}},
    ],
})


def sys_exec(cmd):
    if "vnstat --json" in cmd:
        return vnstat_json
    return ""


# ---------------- stub UCI ----------------
class UCI:
    def __init__(self):
        self.data = {
            "boundlesskuota": {},
            "vnstat": {"cfg01": {".type": "vnstat", "interface": ["br-lan"]}},
        }
        self.counter = 0

    def _sec(self, config, name):
        return self.data.setdefault(config, {}).get(name)

    def get(self, config, name, option=None):
        s = self._sec(config, name)
        if s is None:
            return None
        if option is None:
            return py_to_lua({k: v for k, v in s.items() if not k.startswith(".")})
        v = s.get(option)
        if isinstance(v, list):
            return py_to_lua(v)
        return v

    def get_first(self, config, type_):
        for name, s in self.data.get(config, {}).items():
            if s.get(".type") == type_:
                return name
        return None

    def section(self, config, type_, name=None):
        if name is None:
            self.counter += 1
            name = "cfg%03d" % self.counter
        self.data.setdefault(config, {})[name] = {".type": type_}
        return name

    def set(self, config, name, option, value):
        s = self.data.setdefault(config, {}).setdefault(name, {".type": "?"})
        s[option] = value
        return True

    def delete(self, config, name, option=None):
        secs = self.data.get(config, {})
        if name in secs:
            del secs[name]
            return True
        return False

    def add_list(self, config, name, option, value):
        s = self.data[config][name]
        cur = s.get(option)
        if isinstance(cur, list):
            cur.append(value)
        elif cur is None:
            s[option] = [value]
        else:
            s[option] = [cur, value]
        return True

    def foreach(self, config, type_, fn):
        for name, s in list(self.data.get(config, {}).items()):
            if s.get(".type") == type_:
                m = {k: v for k, v in s.items() if not k.startswith(".")}
                m[".name"] = name
                fn(py_to_lua(m))

    def commit(self, config):
        return True


UCI_OBJ = UCI()
G.UCI_OBJ = UCI_OBJ
G.SYS_EXEC = sys_exec
G.JSON_PARSE = lambda s: py_to_lua(json.loads(s)) if s else None
G.JSON_STRINGIFY = lambda t: json.dumps(lua_to_py(t))
G.FORM = lua.table()

lua.execute(r"""
HTTP_OUT = ""
luci = {
  http = {
    write = function(s) HTTP_OUT = HTTP_OUT .. (s or "") end,
    status = function() end,
    prepare_content = function() end,
    header = function() end,
    formvalue = function(k) return FORM[k] end,
    getenv = function() return "POST" end,
  },
  sys = {
    exec = function(cmd) return SYS_EXEC(cmd) end,
    call = function() return 0 end,
  },
  model = { uci = { cursor = function() return UCI_OBJ end } },
  jsonc = { parse = JSON_PARSE, stringify = JSON_STRINGIFY },
  util = { shellquote = function(s) return "'" .. tostring(s) .. "'" end },
  dispatcher = { test_post_security = function() return true end },
}
nixio = { fs = { access = function() return true end } }
""")

src = open(os.path.join(ROOT, "usr/lib/lua/luci/controller/boundlesskuota.lua"),
           encoding="utf-8").read()
src = src.replace('module("luci.controller.boundlesskuota", package.seeall)', "", 1)
core_path = os.path.join(ROOT, "usr/lib/lua/luci/model/boundlesskuota_core.lua")
src = src.replace('local core = require "luci.model.boundlesskuota_core"',
                  f'local core = dofile("{core_path}")', 1)
lua.execute(src)

passed = failed = 0


def check(cond, name, extra=""):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print(f"GAGAL: {name} {extra}")


def call_action(fn, form=None):
    G.HTTP_OUT = ""
    G.FORM = py_to_lua(form or {})
    getattr(G, fn)()
    out = G.HTTP_OUT
    return json.loads(out) if out else {}


# 1) Status awal: PnP harus mengangkat br-lan dari data pertama.
s = call_action("action_status")
check(s["ok"], "status ok")
check(s["active"]["iface"] == "br-lan", "PnP: interface br-lan", s["active"]["iface"])
check(s["active"]["start"] == "2026-10-24", "PnP: mulai 24 Okt", s["active"]["start"])
check(s["active"]["auto"] == "1", "PnP: auto=1")
c = s["active"]["computed"]
check(c["used_bytes"] == total_bytes, "status: used = total DB", c["used_bytes"])
check(c["blocks"] == 33, "status: 33 blok", c["blocks"])
check(c["paid"] == 129000, "status: Rp129.000", c["paid"])
check(c["day_number"] == 20, "status: hari ke-20", c["day_number"])
check(len(s["history"]) == 0, "status: riwayat kosong")
check(s["health"]["wwan_monitored"] is False, "status: wwan0 belum dimonitor")
check(s["health"]["updated"] == "2026-11-12 12:45", "status: updated vnStat", s["health"]["updated"])

# 2) Setup wwan0 menambahkan ke config vnstat.
r = call_action("action_setup")
check(r["ok"], "setup ok")
s = call_action("action_status")
check(s["health"]["wwan_monitored"] is True, "setup: wwan0 kini dimonitor")

# 3) Koreksi +1 lalu -1.
call_action("action_correct", {"delta": "1"})
s = call_action("action_status")
check(s["active"]["computed"]["paid"] == 132000, "koreksi +1: Rp132.000", s["active"]["computed"]["paid"])
call_action("action_correct", {"delta": "-1"})
s = call_action("action_status")
check(s["active"]["computed"]["paid"] == 129000, "koreksi -1: kembali Rp129.000")

# 4) Ekspor di keadaan bersih.
call_action("action_export")
exp = json.loads(G.HTTP_OUT)
check(exp["app"] == "boundless-kuota", "ekspor: app benar")
check(exp["active"]["start"] == "2026-10-24", "ekspor: active 24 Okt")

# 5) Mulai periode baru hari ini: snapshot anti dobel hitung.
r = call_action("action_start", {"date": "2026-11-12", "opening_blocks": "0"})
check(r["ok"], "start ok", str(r))
s = call_action("action_status")
check(len(s["history"]) == 1, "start: 1 snapshot")
h = s["history"][0]
exp_used = total_bytes - today_bytes
check(h["used_bytes"] == exp_used, "snapshot: used tanpa hari ini", f'{h["used_bytes"]} vs {exp_used}')
check(h["paid"] == 126000, "snapshot: 32 blok = Rp126.000", h["paid"])
check(h["duration_days"] == 19, "snapshot: durasi 19 hari", h["duration_days"])
check(abs(h["hangus_bytes"] - (320_000_000_000 - exp_used)) < 1, "snapshot: hangus 2,88 GB")
check(s["active"]["iface"] == "wwan0", "start: periode baru wwan0", s["active"]["iface"])
check(s["active"]["computed"]["used_bytes"] == 0, "start: wwan0 mulai bersih")
check(s["can_undo"] is True, "start: bisa urungkan")
check(s["totals"]["paid"] == 126000 + 30000, "total: snapshot + dasar periode baru", s["totals"]["paid"])

# 6) Urungkan: semua kembali persis.
r = call_action("action_undo")
check(r["ok"], "undo ok")
s = call_action("action_status")
check(len(s["history"]) == 0, "undo: snapshot prematur terhapus")
check(s["active"]["iface"] == "br-lan", "undo: kembali br-lan")
check(s["active"]["computed"]["paid"] == 129000, "undo: kembali Rp129.000")
check(s["can_undo"] is False, "undo: can_undo mati")

# 7) Pengaturan paket langsung + periode baru memakainya.
r = call_action("action_settings", {
    "mode": "langsung", "base": "30000", "block_gb": "10", "block_rp": "3000",
    "days": "30", "direct_rp": "75000", "direct_gb": "200", "next_iface": "wwan0"})
check(r["ok"], "settings ok", str(r))
call_action("action_start", {"date": "2026-11-12", "opening_blocks": "0"})
s = call_action("action_status")
check(s["active"]["mode"] == "langsung", "periode baru: mode langsung")
check(s["active"]["computed"]["paid"] == 75000, "periode baru: Rp75.000")
call_action("action_undo")

# 8) Impor cadangan memulihkan keadaan bersih.
call_action("action_start", {"date": "2026-11-12", "opening_blocks": "0"})
s = call_action("action_status")
check(len(s["history"]) == 1, "pra-impor: ada snapshot")
r = call_action("action_import", {"data": json.dumps(exp)})
check(r["ok"], "impor ok", str(r))
s = call_action("action_status")
check(len(s["history"]) == 0, "impor: riwayat bersih lagi")
check(s["active"]["iface"] == "br-lan", "impor: active br-lan lagi")
check(s["active"]["mode"] == "blok", "impor: skema blok lagi")
check(s["settings"]["mode"] == "blok", "impor: settings blok lagi")
check(s["active"]["computed"]["paid"] == 129000, "impor: Rp129.000 lagi")

print(f"HASIL SIMULASI: {passed} lulus, {failed} gagal")
sys.exit(0 if failed == 0 else 1)
