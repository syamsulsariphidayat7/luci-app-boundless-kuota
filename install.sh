#!/bin/sh
# luci-app-boundless-kuota - installer lokal (dijalankan DI DALAM STB).
# Menyalin controller + core + view + config, membersihkan cache
# LuCI, restart uhttpd. Config yang sudah ada tidak ditimpa.
# Sejak 0.4.0: tidak ada lagi cron snapshot dan tidak ada PnP
# vnStat — installer juga MEMBERSIHKAN keduanya dari pemasangan
# lama (baris cron boundlesskuota-snapshot + berkas snapshot),
# supaya update benar-benar mematikan snapshot latar.
if [ ! -f /etc/openwrt_release ]; then
	echo "STOP: script ini untuk DI DALAM STB (OpenWrt), bukan di PC/laptop." >&2
	exit 1
fi
set -e

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="usr/lib/lua/luci/controller/boundlesskuota.lua"
CORE="usr/lib/lua/luci/model/boundlesskuota_core.lua"
VIEW="usr/lib/lua/luci/view/boundlesskuota/dashboard.htm"
CFG="etc/config/boundlesskuota"

for f in "$CTL" "$CORE" "$VIEW" "$CFG" "VERSION"; do
	if [ ! -f "$DIR/$f" ]; then
		echo "[boundless-kuota] ERROR: file $f tidak ada di $DIR" >&2
		exit 1
	fi
done

echo "[boundless-kuota] Menyalin file..."
mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/model /usr/lib/lua/luci/view/boundlesskuota /etc/config
cp -f "$DIR/$CTL" "/$CTL"
cp -f "$DIR/$CORE" "/$CORE"
cp -f "$DIR/$VIEW" "/$VIEW"
cp -f "$DIR/VERSION" /usr/lib/lua/luci/view/boundlesskuota/VERSION
if [ -f /etc/config/boundlesskuota ]; then
	echo "[boundless-kuota] Config lama dipertahankan."
else
	cp -f "$DIR/$CFG" /etc/config/boundlesskuota
fi
chmod 644 "/$CTL" "/$CORE" "/$VIEW" /usr/lib/lua/luci/view/boundlesskuota/VERSION /etc/config/boundlesskuota

# Bersihkan warisan <= 0.3.x: cron snapshot API + berkas snapshot.
# Data keadaan /etc/boundlesskuota-api.json TIDAK disentuh — isinya
# (akumulasi pembelian, kumulatif harian, override harga) diteruskan
# oleh 0.4.0 apa adanya.
if [ -f /etc/crontabs/root ] && grep -q "boundlesskuota-snapshot" /etc/crontabs/root; then
	sed -i "/boundlesskuota-snapshot/d" /etc/crontabs/root
	if [ -x /etc/init.d/cron ]; then /etc/init.d/cron restart >/dev/null 2>&1 || true; fi
	echo "[boundless-kuota] Cron snapshot lama dihapus (0.4.0 tanpa snapshot latar)."
fi
if [ -f /usr/bin/boundlesskuota-snapshot ]; then
	rm -f /usr/bin/boundlesskuota-snapshot
	echo "[boundless-kuota] Berkas snapshot lama dihapus."
fi

echo "[boundless-kuota] Membersihkan cache LuCI..."
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-modulecache.* 2>/dev/null || true
if [ -x /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd restart; fi

grep -q "luci.controller.boundlesskuota" "/$CTL" && echo "[boundless-kuota] controller OK"
grep -q "boundlesskuota_core" "/$CORE" && echo "[boundless-kuota] core OK"
[ -f "/$VIEW" ] && echo "[boundless-kuota] view OK (versi $(cat /usr/lib/lua/luci/view/boundlesskuota/VERSION))"
echo "[boundless-kuota] SELESAI. Buka LuCI -> Services -> Monitoring Kuota (hard refresh: Ctrl+F5)."
