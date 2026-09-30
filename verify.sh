#!/bin/bash
#
# verify.sh — verifikasi end-to-end instalasi ZetDNS + laman labuh.
# Jalankan di server zet-dns:  sudo ./verify.sh
# Bisa juga dari luar:         ./verify.sh 49.0.27.27
#
set -uo pipefail

TARGET="${1:-127.0.0.1}"
LOCAL=0
[ "$TARGET" = "127.0.0.1" ] && LOCAL=1

PASS=0
FAIL=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mGAGAL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }

echo "=== Verifikasi ZetDNS (target: $TARGET) ==="
echo

# ---------- 1. service ----------
echo "[1] Service"
if [ "$LOCAL" -eq 1 ]; then
    for u in dnstrust-unbound dnstrust-admin nginx; do
        state="$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
        [ "$state" = "active" ] && ok "$u: active" || bad "$u: $state"
    done
    failed="$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
    [ "$failed" -eq 0 ] && ok "tidak ada unit gagal" || bad "$failed unit gagal"
else
    info "(dilewati — bukan mode lokal)"
fi
echo

# ---------- 2. ACL ----------
echo "[2] ACL terjangkau"
WHOAMI="$(dig +time=6 +tries=1 "@$TARGET" whoami.akamai.net A +short 2>/dev/null | head -1 || true)"
STATUS="$(dig +time=6 +tries=1 "@$TARGET" whoami.akamai.net A 2>/dev/null | grep -oE 'status: [A-Z]+' | head -1 || true)"
if [ -n "$WHOAMI" ]; then
    ok "query diterima ($STATUS): whoami.akamai.net -> $WHOAMI"
    info "kalau nilainya = IP publik server, berarti resolver benar-benar rekursif"
else
    bad "query ditolak/nihil ($STATUS) — IP ini mungkin tidak masuk ACL"
    info "tambah jaringan di /etc/unbound/unbound.conf lalu unbound-control reload"
fi
echo

# ---------- 3. blokir ----------
echo "[3] Domain blokir"
for d in 0--0--1-com.pages.dev pornoxxxsexsatanic.blogspot.com; do
    ip="$(dig +time=6 +tries=1 "@$TARGET" "$d" A +short 2>/dev/null | head -1 || true)"
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
        ok "$d -> $ip"
    elif [ "$ip" = "127.0.0.1" ]; then
        bad "$d -> 127.0.0.1 (masih loopback — klien akan lihat 'connection refused')"
        info "ganti di /etc/unbound/lamanlabuh.conf ke IP server, lalu unbound-control reload"
    else
        info "$d -> kosong (mungkin belum ada di daftar, itu wajar)"
    fi
done
echo

# ---------- 4. domain normal ----------
echo "[4] Domain normal tidak terblokir"
for d in cloudflare.com example.com; do
    ip="$(dig +time=6 +tries=1 "@$TARGET" "$d" A +short 2>/dev/null | head -1 || true)"
    [ -n "$ip" ] && ok "$d -> $ip" || bad "$d tidak resolve"
done
echo

# ---------- 5. halaman blokir ----------
echo "[5] Halaman blokir"
if [ "$LOCAL" -eq 1 ]; then
    TITLE="$(curl -sS -H 'Host: situsblokir.test' "http://127.0.0.1/" --max-time 8 2>/dev/null \
             | grep -oE '<title>[^<]*</title>' | head -1 || true)"
    if echo "$TITLE" | grep -q Trustpositif; then
        ok "catch-all default_server: $TITLE"
    else
        bad "halaman tidak ketemu: '$TITLE'"
        info "cek: rm -f /etc/nginx/sites-enabled/default && systemctl restart nginx"
    fi
    if grep -q "cdn.jsdelivr.net" /var/www/lamanlabuh/index.html 2>/dev/null; then
        bad "halaman masih bergantung CDN Bootstrap"
    else
        ok "CSS Bootstrap sudah inline (tidak butuh internet)"
    fi
else
    CODE="$(curl -sS -H 'Host: situsblokir.test' "http://$TARGET/" --max-time 8 -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
    [ "$CODE" = "200" ] && ok "halaman blokir http=$CODE" || bad "halaman blokir http=$CODE"
fi
echo

# ---------- 6. rekursif, bukan forwarder ----------
echo "[6] Rekursif vs forwarder"
if [ "$LOCAL" -eq 1 ]; then
    CONF="/etc/unbound/unbound.conf"
    if grep -qE '^\s*include:\s*"/etc/unbound/forwarder\.conf"' "$CONF" 2>/dev/null; then
        FWD="$(grep -vE '^\s*#|^\s*$' /etc/unbound/forwarder.conf 2>/dev/null | wc -l)"
        [ "$FWD" -eq 0 ] && ok "forwarder.conf kosong (komentar semua) = rekursif murni" \
                         || bad "forwarder.conf punya $FWD baris aktif"
    else
        info "forwarder.conf tidak di-include"
    fi
    if [ -f /etc/unbound/safesearch.conf ]; then
        note="$(grep -oE 'force[s]?afesearch' /etc/unbound/rpz.safesearch 2>/dev/null | head -1 || true)"
        [ -n "$note" ] && info "SafeSearch aktif (google.* -> forcesafesearch.google.com)"
    fi
else
    info "(dilewati — butuh akses file config)"
fi
echo

# ---------- 7. resource ----------
echo "[7] Resource"
if [ "$LOCAL" -eq 1 ]; then
    MP="$(systemctl show dnstrust-unbound -p MainPID --value 2>/dev/null || echo 0)"
    if [ "$MP" != "0" ] && [ -n "$MP" ]; then
        ps -o rss=,pcpu= -p "$MP" 2>/dev/null | awk '{printf "  OK    Unbound RSS=%.1f MB  CPU=%s%%\n", $1/1024, $2}'
        PASS=$((PASS+1))
    fi
    if [ -f /var/lib/dnstrust/trust.count ]; then
        ok "domain aktif: $(cat /var/lib/dnstrust/trust.count)"
    fi
    [ -f /var/lib/dnstrust/blacklist.db ] && \
        ok "blacklist.db: $(du -h /var/lib/dnstrust/blacklist.db | cut -f1)"
    df -h / | awk 'NR==2{printf "  OK    disk root: %s terpakai dari %s (%s)\n", $3, $2, $5}'
    PASS=$((PASS+1))
else
    info "(dilewati — butuh mode lokal)"
fi
echo

# ---------- ringkasan ----------
echo "==================================="
printf "LULUS: %d   GAGAL: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "SEMUA BAIK" || echo "ADA MASALAH — lihat baris GAGAL di atas"
exit "$FAIL"
