#!/bin/sh
# luci-app-boundless-kuota - installer lokal (dijalankan DI DALAM STB).
# Menyalin controller + core + view + config, mengaktifkan monitoring
# wwan0 di vnStat (PnP), membersihkan cache LuCI, restart uhttpd.
# Config yang sudah ada tidak ditimpa.
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

# PnP: pastikan vnStat ikut mencatat interface modem wwan0 mulai
# sekarang, supaya periode berikutnya bisa memakai data modem.
# Kegagalan di sini tidak menggagalkan pemasangan; dashboard punya
# tombol setup manual sebagai cadangan.
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/vnstat ]; then
	IFLIST=$(uci -q get vnstat.@vnstat[0].interface 2>/dev/null || true)
	case " $IFLIST " in
	*" wwan0 "*)
		echo "[boundless-kuota] vnStat sudah memonitor wwan0."
		;;
	*)
		echo "[boundless-kuota] Mengaktifkan monitoring wwan0 di vnStat..."
		if uci add_list vnstat.@vnstat[0].interface='wwan0' 2>/dev/null && uci commit vnstat 2>/dev/null; then
			if [ -x /etc/init.d/vnstat ]; then /etc/init.d/vnstat restart >/dev/null 2>&1 || true; fi
			echo "[boundless-kuota] wwan0 aktif dimonitor vnStat."
		else
			echo "[boundless-kuota] PERINGATAN: gagal mengubah config vnStat; pakai tombol setup di dashboard."
		fi
		;;
	esac
fi

echo "[boundless-kuota] Membersihkan cache LuCI..."
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-modulecache.* 2>/dev/null || true
if [ -x /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd restart; fi

grep -q "luci.controller.boundlesskuota" "/$CTL" && echo "[boundless-kuota] controller OK"
grep -q "boundlesskuota_core" "/$CORE" && echo "[boundless-kuota] core OK"
[ -f "/$VIEW" ] && echo "[boundless-kuota] view OK (versi $(cat /usr/lib/lua/luci/view/boundlesskuota/VERSION))"
echo "[boundless-kuota] SELESAI. Buka LuCI -> Services -> Monitoring Kuota (hard refresh: Ctrl+F5)."
