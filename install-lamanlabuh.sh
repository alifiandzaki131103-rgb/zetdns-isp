#!/bin/bash
#
# install-lamanlabuh.sh — pasang halaman blokir (laman labuh) untuk ZetDNS
# dan arahkan domain blokir ke IP server.
#
# Pemakaian:
#   sudo ./install-lamanlabuh.sh --dns-ip 10.0.0.53
#   sudo ./install-lamanlabuh.sh --dns-ip 10.0.0.53 --document-root /var/www/lamanlabuh
#
set -euo pipefail

DNS_IP=""
DOC_ROOT="/var/www/lamanlabuh"
UNBOUND_CONF="/etc/unbound/unbound.conf"
LAMANLABUH_CONF="/etc/unbound/lamanlabuh.conf"
NGINX_AVAIL="/etc/nginx/sites-available/lamanlabuh"
NGINX_ENABLED="/etc/nginx/sites-enabled/lamanlabuh"
BACKUP_DIR="/root/zetdns-backups"

# ---------- argumen ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --dns-ip)         DNS_IP="${2:-}"; shift 2 ;;
        --document-root)  DOC_ROOT="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "argumen tidak dikenal: $1" >&2; exit 2 ;;
    esac
done

# ---------- validasi awal ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: jalankan sebagai root (sudo)." >&2
    exit 1
fi

if [ -z "$DNS_IP" ]; then
    echo "ERROR: --dns-ip wajib. Ini IP server yang akan dikunjungi klien saat domain diblokir." >&2
    echo "" >&2
    echo "  Cari IP server:" >&2
    ip -4 addr show scope global | awk '/inet /{print "    " $2 "  (" $NF ")"}' >&2
    exit 1
fi

if ! python3 -c "import ipaddress,sys; ipaddress.ip_address(sys.argv[1])" "$DNS_IP" 2>/dev/null; then
    echo "ERROR: '$DNS_IP' bukan alamat IP yang valid." >&2
    exit 1
fi

if [ ! -x /usr/local/sbin/unbound-control ]; then
    echo "ERROR: zet-dns belum terinstall (unbound-control tidak ada)." >&2
    echo "       Jalankan install zet-dns dulu." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== ZetDNS laman labuh installer ==="
echo "  DNS IP       : $DNS_IP"
echo "  Document root: $DOC_ROOT"
echo "  Sumber       : $SCRIPT_DIR"
echo

mkdir -p "$BACKUP_DIR"

backup() {
    # backup() <file> — salin sekali saja, agar rollback tidak menimpa backup asli
    local f="$1" base
    [ -e "$f" ] || return 0
    base="$BACKUP_DIR/$(echo "$f" | tr '/' '_').before-lamanlabuh"
    if [ ! -e "$base" ]; then
        cp -a "$f" "$base"
        echo "    backup: $f -> $base"
    else
        echo "    backup sudah ada: $base"
    fi
}

# ---------- 1. pastikan nginx ada ----------
echo "[1/7] Cek nginx"
if ! command -v nginx >/dev/null 2>&1; then
    echo "    nginx tidak ada, install..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
fi
nginx -v 2>&1 | sed 's/^/    /'

# ---------- 2. pasang halaman ----------
echo "[2/7] Pasang halaman blokir ke $DOC_ROOT"
if [ ! -f "$SCRIPT_DIR/lamanlabuh/index.html" ]; then
    echo "ERROR: $SCRIPT_DIR/lamanlabuh/index.html tidak ditemukan." >&2
    exit 1
fi
mkdir -p "$DOC_ROOT"
backup "$DOC_ROOT/index.html"
cp "$SCRIPT_DIR/lamanlabuh/index.html" "$DOC_ROOT/index.html"
chown -R www-data:www-data "$DOC_ROOT" 2>/dev/null || true
chmod 755 "$DOC_ROOT"
chmod 644 "$DOC_ROOT/index.html"
echo "    $(stat -c '%s bytes' "$DOC_ROOT/index.html")"

# ---------- 3. nginx vhost ----------
echo "[3/7] Pasang nginx vhost"
backup "$NGINX_AVAIL"
cp "$SCRIPT_DIR/config/nginx/lamanlabuh.conf" "$NGINX_AVAIL"

# ganti document root kalau bukan default
if [ "$DOC_ROOT" != "/var/www/lamanlabuh" ]; then
    sed -i "s|root /var/www/lamanlabuh;|root $DOC_ROOT;|" "$NGINX_AVAIL"
fi

if [ -e /etc/nginx/sites-enabled/default ]; then
    backup /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default
    echo "    default site bawaan dimatikan (bentrok default_server)"
fi

ln -sf "$NGINX_AVAIL" "$NGINX_ENABLED"

if ! nginx -t 2>&1 | sed 's/^/    /'; then
    echo "ERROR: nginx config tidak valid. Cek output di atas." >&2
    exit 1
fi

# restart, bukan reload: default_server baru tidak diterapkan oleh reload
systemctl restart nginx
systemctl is-active nginx | sed 's/^/    nginx: /'

# ---------- 4. arahkan domain blokir ----------
echo "[4/7] Arahkan domain blokir ke $DNS_IP"
if [ ! -f "$LAMANLABUH_CONF" ]; then
    echo "ERROR: $LAMANLABUH_CONF tidak ada. zet-dns belum terinstall sempurna." >&2
    exit 1
fi
backup "$LAMANLABUH_CONF"
OLD_IP="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$LAMANLABUH_CONF" | head -1 || true)"
sed -i -E "s|\"blacklist\. 60 IN A [0-9.]+\"|\"blacklist. 60 IN A $DNS_IP\"|" "$LAMANLABUH_CONF"
echo "    $OLD_IP -> $DNS_IP"
cat "$LAMANLABUH_CONF" | sed 's/^/    /'

# ---------- 5. validasi + reload unbound ----------
echo "[5/7] Validasi unbound"
backup "$UNBOUND_CONF"
if ! /usr/local/sbin/unbound-checkconf "$UNBOUND_CONF" 2>&1 | sed 's/^/    /'; then
    echo "ERROR: unbound config tidak valid." >&2
    echo "       Rollback: cp -a $BACKUP_DIR/etc_unbound_lamanlabuh.conf.before-lamanlabuh $LAMANLABUH_CONF" >&2
    exit 1
fi
/usr/local/sbin/unbound-control reload 2>&1 | sed 's/^/    /'

# ---------- 6. verifikasi ----------
echo "[6/7] Verifikasi"
sleep 1
FAIL=0

# 6a. DNS blokir
BLOCKED_IP="$(dig +time=5 +tries=1 @127.0.0.1 0--0--1-com.pages.dev A +short 2>/dev/null | head -1 || true)"
if [ "$BLOCKED_IP" = "$DNS_IP" ]; then
    echo "    OK  domain blokir -> $BLOCKED_IP"
else
    echo "    GAGAL domain blokir -> '$BLOCKED_IP' (harusnya $DNS_IP)"
    FAIL=1
fi

# 6b. domain normal tidak ikut terblokir
NORMAL_IP="$(dig +time=5 +tries=1 @127.0.0.1 cloudflare.com A +short 2>/dev/null | head -1 || true)"
if [ -n "$NORMAL_IP" ] && [ "$NORMAL_IP" != "$DNS_IP" ]; then
    echo "    OK  domain normal -> $NORMAL_IP"
else
    echo "    GAGAL cloudflare.com -> '$NORMAL_IP'"
    FAIL=1
fi

# 6c. halaman blokir
TITLE="$(curl -sS -H 'Host: situsblokir.test' "http://127.0.0.1/" --max-time 8 2>/dev/null \
         | grep -oE '<title>[^<]*</title>' | head -1 || true)"
if echo "$TITLE" | grep -q "Trustpositif"; then
    echo "    OK  halaman blokir: $TITLE"
else
    echo "    GAGAL halaman blokir: '$TITLE'"
    echo "         Cek: ls -la $DOC_ROOT/index.html; nginx -T | grep -A3 default_server"
    FAIL=1
fi

# 6d. tabrakan default_server
DUP="$(grep -rl 'default_server' /etc/nginx/sites-enabled/ 2>/dev/null | wc -l)"
if [ "$DUP" -gt 1 ]; then
    echo "    PERINGATAN: $DUP vhost punya default_server — bisa tabrakan"
    grep -rn 'default_server' /etc/nginx/sites-enabled/ | sed 's/^/      /'
fi

# ---------- 7. ringkasan ----------
echo "[7/7] Selesai"
echo
if [ "$FAIL" -eq 0 ]; then
    echo "SEMUA VERIFIKASI LULUS"
else
    echo "ADA VERIFIKASI GAGAL — lihat output di atas"
fi
echo
echo "Backup ada di: $BACKUP_DIR"
echo
echo "Langkah berikutnya:"
echo "  1. Pastikan daftar Komdigi sudah ditarik:"
echo "       systemctl start unbound-blacklist-update.service"
echo "       journalctl -u unbound-blacklist-update -f"
echo "  2. Set DNS pelanggan ke $DNS_IP (lewat DHCP / PPPoE pool)"
echo "  3. Ganti password root dan password dashboard (:9080)"
echo
echo "Rollback:"
echo "  cp -a $BACKUP_DIR/etc_unbound_lamanlabuh.conf.before-lamanlabuh $LAMANLABUH_CONF"
echo "  rm -f $NGINX_ENABLED"
echo "  systemctl restart nginx && /usr/local/sbin/unbound-control reload"

exit "$FAIL"
