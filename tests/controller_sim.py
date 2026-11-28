#!/usr/bin/env python3
"""Simulasi controller boundlesskuota 0.4.0 di VM: stub luci.* +
UCI di Python, backend Sunset difixture (welcome + history).
Menguji: periode pertama, pembelian tercatat + override harga,
akumulasi sadar-reset, keadaan basi saat API mati, tutup/urungkan
periode (snapshot berisi daftar pembelian; override bertahan
lintas periode), pengaturan, ekspor/impor, reset.
"""
import datetime as _dt
import json
import os
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GB = 1_073_741_824

os.environ["BK_API_STATE"] = "/tmp/bk-api-state-test40.json"
if os.path.exists(os.environ["BK_API_STATE"]):
    os.remove(os.environ["BK_API_STATE"])

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


# ---------------- fixture backend Sunset ----------------
TODAY = _dt.date.today()
YEST = TODAY - _dt.timedelta(days=1)
TOMORROW = TODAY + _dt.timedelta(days=1)


def noon_ts(d):
    return int(_dt.datetime(d.year, d.month, d.day, 12,
                            tzinfo=_dt.timezone.utc).timestamp())


WELCOME = {"ok": True, "number": "628123456", "quotas": [
    {"name": "Xtra Combo Plus", "expired_at": 1797000000,
     "total_bytes": 20 * GB, "remaining_bytes": 20 * GB},
    {"name": "Bonus Kuota Instagram 10GB", "expired_at": 1796000000,
     "total_bytes": 10 * GB, "remaining_bytes": 10 * GB},
    {"name": "Quota Bonus 5G", "expired_at": 1798000000,
     "total_bytes": 100 * GB, "remaining_bytes": 100 * GB},
]}
HISTORY = {"ok": True, "transactions": [
    {"timestamp": noon_ts(YEST), "title": "Xtra Combo Plus", "price": 35000,
     "status": "SUCCESS", "payment_status": "", "payment_method": "", "trx_code": "X1"},
    {"timestamp": noon_ts(YEST), "title": "Bonus Kuota Instagram 10GB", "price": 3000,
     "status": "SUCCESS", "payment_status": "", "payment_method": "", "trx_code": "G1"},
    {"timestamp": noon_ts(YEST), "title": "Bonus Kuota Instagram 10GB", "price": 3000,
     "status": "SUCCESS", "payment_status": "", "payment_method": "", "trx_code": "G2"},
    {"timestamp": noon_ts(YEST), "title": "Reload", "price": 25000,
     "status": "SUCCESS", "payment_status": "", "payment_method": "", "trx_code": "R1"},
    {"timestamp": noon_ts(TODAY), "title": "Bonus Kuota Instagram 10GB", "price": 3000,
     "status": "SUCCESS", "payment_status": "", "payment_method": "", "trx_code": "G4"},
    {"timestamp": noon_ts(TODAY), "title": "Bonus Kuota Instagram 10GB", "price": 3000,
     "status": "FAILED", "payment_status": "", "payment_method": "", "trx_code": "G5"},
]}
API_DOWN = {"welcome": False}


def sys_exec_api(cmd):
    if "/api/luci/welcome" in cmd:
        return "" if API_DOWN["welcome"] else json.dumps(WELCOME)
    if "/api/luci/history" in cmd:
        return json.dumps(HISTORY)
    return ""


def set_welcome(xcp_rem_gb, ig_rem_gb):
    WELCOME["quotas"][0]["remaining_bytes"] = int(xcp_rem_gb * GB)
    WELCOME["quotas"][1]["remaining_bytes"] = int(ig_rem_gb * GB)


# ---------------- stub UCI ----------------
class UCI:
    def __init__(self):
        self.data = {
            "boundlesskuota": {},
            "sunset": {"settings": {".type": "settings",
                                    "api_url": "https://fixture.sunset",
                                    "secret": "testsecret"}},
        }
        self.counter = 0

    def _sec(self, config, name):
        return self.data.setdefault(config, {}).get(name)

    def get(self, config, name, option=None):
        # Meniru libuci asli: get TANPA opsi tidak mengembalikan isi
        # section (itu tugas get_all) — kembalikan None agar controller
        # yang bergantung padanya ketahuan saat uji.
        if option is None:
            return None
        s = self._sec(config, name)
        if s is None:
            return None
        v = s.get(option)
        if isinstance(v, list):
            return py_to_lua(v)
        return v

    def get_all(self, config, name):
        s = self._sec(config, name)
        if s is None:
            return None
        return py_to_lua({k: v for k, v in s.items() if not k.startswith(".")})

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
G.SYS_EXEC = sys_exec_api
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


# 1) Keadaan segar: belum ada periode.
s = call_action("action_status")
check(s["ok"], "status ok")
check(s.get("active") is None, "awal: belum ada periode aktif")
check(s["health"]["has_active"] is False, "awal: health tanpa periode")
check(s["settings"]["days"] == "28", "awal: masa aktif bawaan 28 hari")
check(len(s["history"]) == 0, "awal: riwayat kosong")

# 2) Tanggal masa depan ditolak; periode pertama dibuat (mundur 1 hari).
r = call_action("action_start", {"date": TOMORROW.isoformat(), "days": "28"})
check(not r["ok"], "start: tanggal masa depan ditolak")
r = call_action("action_start", {"date": YEST.isoformat(), "days": "28"})
check(r["ok"], "start: periode pertama dibuat", str(r))

# 3) Status: API aktif, pembelian jendela periode terbaca penuh.
s = call_action("action_status")
check(s["health"]["api_active"] is True, "api: terhubung")
c = s["active"]["computed"]
check(c["used_bytes"] == 0, "api: terpakai awal 0")
check(c["remaining_bytes"] == 130 * GB, "api: belum ada aktivitas -> sisa = semua paket live",
      str(c["remaining_bytes"]))
check(c["remaining_all_bytes"] == 130 * GB, "api: sisa semua paket 130 GB")
check(s["api"]["purchases_count"] == 4, "api: 4 pembelian SUCCESS paket (Reload+FAILED tersaring)",
      str(s["api"].get("purchases_count")))
check(s["api"]["purchases_total"] == 44000, "api: total tercatat Rp44.000",
      str(s["api"].get("purchases_total")))
check(c["purchases_total"] == 44000, "api: headline biaya = tercatat")
check(c["day_number"] == 2, "api: hari ke-2", str(c["day_number"]))

# 4) Override harga riil XCP 35.000 -> 30.000.
r = call_action("action_txprice", {"key": "c:X1", "price": "30000"})
check(r["ok"], "txprice: override tersimpan", str(r))
s = call_action("action_status")
check(s["api"]["purchases_total"] == 39000, "txprice: total jadi Rp39.000",
      str(s["api"].get("purchases_total")))
_it = [p for p in s["api"]["purchases"] if p.get("key") == "c:X1"]
check(len(_it) == 1 and _it[0]["price"] == 30000 and _it[0].get("overridden") is True,
      "txprice: baris XCP bertanda override")

# 5-8) Pertumbuhan + reset bucket IG (beli saat habis, tidak menumpuk).
set_welcome(20, 6)
s = call_action("action_status")
check(s["active"]["computed"]["used_bytes"] == 4 * GB, "reset: IG terpakai 4 GB")
check(s["active"]["computed"]["remaining_bytes"] == 6 * GB,
      "sisa: hanya bucket aktif (IG 6 GB; XCP belum bergerak, 5G kuota khusus)",
      str(s["active"]["computed"]["remaining_bytes"]))
check(s["active"]["computed"]["remaining_all_bytes"] == 126 * GB, "sisa: semua paket 126 GB")
set_welcome(20, 0)
s = call_action("action_status")
check(s["active"]["computed"]["used_bytes"] == 10 * GB, "reset: IG habis = 10 GB")
set_welcome(20, 10)
s = call_action("action_status")
check(s["active"]["computed"]["used_bytes"] == 10 * GB,
      "reset: sesudah beli lagi total tetap 10 GB (bukan 0, bukan 20)")
set_welcome(18, 7)
s = call_action("action_status")
c = s["active"]["computed"]
check(c["used_bytes"] == 15 * GB, "reset: XCP +2 & IG bucket baru +3 = 15 GB",
      str(c["used_bytes"]))
check(abs(c["price_per_gb"] - 2600) < 1, "harga/GB efektif = 39.000/15 = Rp2.600",
      str(c["price_per_gb"]))
check(c["remaining_bytes"] == 25 * GB, "sisa bucket aktif kini 25 GB (XCP 18 + IG 7)")
check(c["remaining_all_bytes"] == 125 * GB, "sisa semua paket 125 GB (termasuk 5G 100 GB)")
_bk = {b["name"]: b for b in s["api"]["buckets"]}
check(len(_bk) == 3, "bucket: rincian 3 bucket dari operator")
check(_bk["Quota Bonus 5G"]["active"] is False, "bucket: 5G ditandai tidak terpakai")
check(_bk["Bonus Kuota Instagram 10GB"]["active"] is True, "bucket: IG ditandai aktif")

# 9) Tabel harian: biaya mengikuti tanggal beli riil.
rows = {r["date"]: r for r in c["daily"]}
check(rows[YEST.isoformat()]["cost"] == 36000, "harian: biaya kemarin Rp36.000 (XCP override + 2 IG)",
      str(rows[YEST.isoformat()]))
check(rows[YEST.isoformat()]["bytes"] == 0, "harian: kemarin tanpa catatan pemakaian (state lahir hari ini)")
check(rows[TODAY.isoformat()]["bytes"] == 15 * GB, "harian: pemakaian menumpuk di hari ambil")
check(rows[TODAY.isoformat()]["cost"] == 3000, "harian: biaya hari ini Rp3.000 (G4)")
check(rows[TODAY.isoformat()]["cum_cost"] == 39000, "harian: biaya kumulatif Rp39.000")
check(abs(rows[TODAY.isoformat()]["price_per_gb"] - 2600) < 1, "harian: harga/GB kumulatif Rp2.600")

# 10) API mati: angka terakhir tampil apa adanya, ditandai basi.
API_DOWN["welcome"] = True
s = call_action("action_status")
check(s["health"]["api_stale"] is True, "basi: ditandai saat API mati")
check(s["health"]["api_active"] is False, "basi: api tidak aktif")
check(s["active"]["computed"]["used_bytes"] == 15 * GB, "basi: terpakai terakhir dipertahankan")
check(s["api"]["purchases_total"] == 39000, "basi: tercatat terakhir dipertahankan")
check(s["api"]["last_fetch"] is not None, "basi: ada cap waktu ambil terakhir")
API_DOWN["welcome"] = False

# 11) Pengaturan: hanya masa aktif.
r = call_action("action_settings", {"days": "30"})
check(r["ok"], "settings: 30 hari ok")
r = call_action("action_settings", {"days": "0"})
check(not r["ok"], "settings: 0 hari ditolak")
s = call_action("action_status")
check(s["settings"]["days"] == "30", "settings: tersimpan 30")

# 11b) Override transaksi hari ini (G4) — harus bertahan lintas periode.
r = call_action("action_txprice", {"key": "c:G4", "price": "2500"})
check(r["ok"], "txprice: override G4 ok")
s = call_action("action_status")
check(s["api"]["purchases_total"] == 38500, "txprice: total berjalan Rp38.500")

# 12) Tutup periode hari ini: snapshot = pembelian di jendela lama.
r = call_action("action_start", {"date": TODAY.isoformat()})
check(r["ok"], "tutup: periode baru dimulai", str(r))
s = call_action("action_status")
check(len(s["history"]) == 1, "tutup: 1 snapshot")
h = s["history"][0]
check(h["paid"] == 36000, "snapshot: biaya = pembelian tercatat jendela lama Rp36.000",
      str(h["paid"]))
check(h["purchases_count"] == 3, "snapshot: 3 pembelian tersimpan")
check(len(h.get("purchases") or []) == 3, "snapshot: daftar pembelian permanen ikut")
check(h["used_bytes"] == 15 * GB, "snapshot: terpakai s/d penutupan 15 GB",
      str(h["used_bytes"]))
check(h["duration_days"] == 1, "snapshot: durasi 1 hari")
check(s["can_undo"] is True, "tutup: bisa urungkan")
check(s["active"]["start"] == TODAY.isoformat(), "tutup: periode baru mulai hari ini")
check(s["active"]["days"] == 30, "tutup: periode baru memakai masa aktif tersimpan (30)")
c = s["active"]["computed"]
check(c["used_bytes"] == 0, "periode baru: terpakai mulai 0")
check(c["purchases_total"] == 2500, "periode baru: G4 hari ini + override bertahan = Rp2.500",
      str(c["purchases_total"]))
check(s["totals"]["paid"] == 38500, "total keseluruhan konsisten Rp38.500",
      str(s["totals"]["paid"]))

# 13) Urungkan: semua kembali persis.
r = call_action("action_undo")
check(r["ok"], "undo ok")
s = call_action("action_status")
check(len(s["history"]) == 0, "undo: snapshot prematur terhapus")
check(s["active"]["start"] == YEST.isoformat(), "undo: periode lama aktif lagi")
check(s["api"]["purchases_total"] == 38500, "undo: tercatat kembali Rp38.500")
check(s["can_undo"] is False, "undo: can_undo mati")

# 14) Ekspor -> tutup lagi -> impor memulihkan.
call_action("action_export")
exp = json.loads(G.HTTP_OUT)
check(exp["app"] == "boundless-kuota", "ekspor: app benar")
check(exp["active"]["start"] == YEST.isoformat(), "ekspor: active kemarin")
check(exp.get("api_state") is not None, "ekspor: keadaan API ikut")
call_action("action_start", {"date": TODAY.isoformat()})
s = call_action("action_status")
check(len(s["history"]) == 1, "pra-impor: ada snapshot")
r = call_action("action_import", {"data": json.dumps(exp)})
check(r["ok"], "impor ok", str(r))
s = call_action("action_status")
check(len(s["history"]) == 0, "impor: riwayat bersih lagi")
check(s["active"]["start"] == YEST.isoformat(), "impor: active kemarin lagi")
check(s["api"]["purchases_total"] == 38500, "impor: tercatat + override pulih Rp38.500")

# 14) Koreksi terpakai: lubang warisan ditutup dari pembelian.
_sp = os.environ["BK_API_STATE"]
with open(_sp) as _f:
    _st = json.load(_f)
_st["offset"] = _st.get("offset", 0) - 5 * GB
with open(_sp, "w") as _f:
    json.dump(_st, _f)
s = call_action("action_status")
check(s["active"]["computed"]["used_bytes"] == 10 * GB,
      "koreksi: terpakai turun ke 10 GB sesudah offset dirusak",
      str(s["active"]["computed"]["used_bytes"]))
ci = call_action("action_correctinfo")
check(ci.get("ok") is True, "koreksi: pratinjau tersedia")
corr = ci["correction"]
check(corr["target_bytes"] == 25 * GB, "koreksi: target = hitungan pembelian 25 GB",
      str(corr["target_bytes"]))
check(corr["delta_bytes"] == 15 * GB, "koreksi: delta +15 GB")
_crows = {r["name"]: r for r in corr["rows"]}
check(_crows["Bonus Kuota Instagram 10GB"]["buys"] == 3, "koreksi: IG terhitung 3 pembelian")
check(_crows["Bonus Kuota Instagram 10GB"]["target_bytes"] == 23 * GB,
      "koreksi: target IG = 3x10 - sisa 7 = 23 GB")
check(_crows["Xtra Combo Plus"]["buys"] == 1, "koreksi: XCP terhitung 1 pembelian")
r = call_action("action_correct")
check(r.get("ok") is True and r["used_bytes"] == 25 * GB,
      "koreksi: terpakai menjadi 25 GB sesudah diterapkan")
s = call_action("action_status")
check(s["active"]["computed"]["used_bytes"] == 25 * GB, "koreksi: status konsisten 25 GB")
check(s["api"]["correction"]["delta_bytes"] == 15 * GB, "koreksi: catatan koreksi tersimpan")
_drows = {row["date"]: row for row in s["active"]["computed"]["daily"]}
check(_drows[TODAY.isoformat()]["cum_bytes"] == 25 * GB, "koreksi: kumulatif hari ini 25 GB")
check(_drows[TODAY.isoformat()]["bytes"] == 25 * GB,
      "koreksi: satu titik tercatat — pemakaian hari ini ikut target baru")
ci2 = call_action("action_correctinfo")
check(ci2["correction"]["delta_bytes"] == 0, "koreksi: idempoten — delta kedua 0")


# 15) Reset data app.
r = call_action("action_reset")
check(r["ok"], "reset ok", str(r))
s = call_action("action_status")
check(s.get("active") is None, "reset: tidak ada periode")
check(len(s["history"]) == 0, "reset: riwayat kosong")
check(s["can_undo"] is False, "reset: tidak bisa urungkan")

print(f"HASIL SIMULASI: {passed} lulus, {failed} gagal")
sys.exit(0 if failed == 0 else 1)
