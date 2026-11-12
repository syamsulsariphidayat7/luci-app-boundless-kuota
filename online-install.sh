#!/bin/sh
# luci-app-boundless-kuota - installer ONLINE (dijalankan DI DALAM STB).
# Mengunduh tarball rilis terbaru dari GitHub, menjalankan install.sh
# di dalamnya, lalu menyimpan salinan di /root untuk copot/rollback.
# Pilihan: VERSION=0.1.0 (paksa tag) atau BRANCH=main (branch mentah).
set -e

if [ ! -f /etc/openwrt_release ]; then
	echo "STOP: script ini untuk DI DALAM STB (OpenWrt), bukan di PC/laptop." >&2
	exit 1
fi

REPO="syamsulsariphidayat7/luci-app-boundless-kuota"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM

fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1" -o "$2"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		echo "[boundless-kuota] ERROR: curl dan wget tidak ditemukan." >&2
		exit 1
	fi
}

if [ -n "$BRANCH" ]; then
	URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"
	REFDESC="branch $BRANCH"
elif [ -n "$VERSION" ]; then
	TAG="v${VERSION#v}"
	URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
	REFDESC="rilis $TAG"
else
	TAG=""
	if fetch "https://api.github.com/repos/$REPO/tags?per_page=1" "$TMPD/tags.json" 2>/dev/null; then
		TAG=$(grep -o '"name": *"[^"]*"' "$TMPD/tags.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
	fi
	if [ -n "$TAG" ]; then
		URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
		REFDESC="rilis terbaru $TAG"
	else
		URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
		REFDESC="branch main"
	fi
fi

echo "[boundless-kuota] Download $REFDESC..."
fetch "$URL" "$TMPD/app.tar.gz"
tar -xzf "$TMPD/app.tar.gz" -C "$TMPD"
ROOT=$(find "$TMPD" -maxdepth 1 -type d -name 'luci-app-boundless-kuota-*' | head -1)
if [ -z "$ROOT" ] || [ ! -f "$ROOT/install.sh" ]; then
	echo "[boundless-kuota] ERROR: isi tarball tidak sesuai. Repo sudah di-push & Public?" >&2
	exit 1
fi

( cd "$ROOT" && sh install.sh )

rm -rf /root/luci-app-boundless-kuota
cp -r "$ROOT" /root/luci-app-boundless-kuota
cp -f "$ROOT/uninstall.sh" /root/luci-app-boundless-kuota-uninstall.sh
chmod 755 /root/luci-app-boundless-kuota-uninstall.sh

echo "[boundless-kuota] SELESAI ($REFDESC). Buka LuCI -> Services -> Monitoring Kuota."
echo "[boundless-kuota] Copot: sh /root/luci-app-boundless-kuota-uninstall.sh"
