#!/bin/sh
# luci-app-boundless-kuota - uninstaller (dijalankan DI DALAM STB).
# Menghapus controller + core + view dan cache LuCI. Config
# /etc/config/boundlesskuota dipertahankan, kecuali argumen: purge
# Monitoring wwan0 di vnStat TIDAK dimatikan (data vnStat milik
# sistem; menghapusnya merusak riwayat traffic).
if [ ! -f /etc/openwrt_release ]; then
	echo "STOP: script ini untuk DI DALAM STB (OpenWrt), bukan di PC/laptop." >&2
	exit 1
fi
set -e

echo "[boundless-kuota] Menghapus file aplikasi..."
rm -f /usr/lib/lua/luci/controller/boundlesskuota.lua
rm -f /usr/lib/lua/luci/model/boundlesskuota_core.lua
rm -rf /usr/lib/lua/luci/view/boundlesskuota
rm -f /usr/bin/boundlesskuota-snapshot
if [ -f /etc/crontabs/root ] && grep -q "boundlesskuota-snapshot" /etc/crontabs/root; then
	sed -i "/boundlesskuota-snapshot/d" /etc/crontabs/root
	if [ -x /etc/init.d/cron ]; then /etc/init.d/cron restart >/dev/null 2>&1 || true; fi
	echo "[boundless-kuota] Cron snapshot API dihapus."
fi

if [ "$1" = "purge" ]; then
	echo "[boundless-kuota] purge: config ikut dihapus."
	rm -f /etc/config/boundlesskuota
	rm -f /etc/boundlesskuota-api.json /etc/boundlesskuota-api.json.lastclose
	rm -rf /root/luci-app-boundless-kuota
	rm -f /root/luci-app-boundless-kuota-uninstall.sh
else
	echo "[boundless-kuota] Config dipertahankan (argumen 'purge' untuk menghapusnya juga)."
fi

echo "[boundless-kuota] Membersihkan cache LuCI..."
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-modulecache.* 2>/dev/null || true
if [ -x /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd restart; fi

echo "[boundless-kuota] SELESAI. Menu Services -> Monitoring Kuota sudah hilang."
