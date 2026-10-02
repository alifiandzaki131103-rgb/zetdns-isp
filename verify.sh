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
SKIP=0
DNS_DEAD=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mGAGAL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mLEWAT\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
info() { printf '        %s\n' "$1"; }

# dig yang benar: bedakan "perintah jalan" dari "jawaban benar".
# dig tetap exit 0 walau resolver mati -> wajib periksa isi jawabannya.
# Hasil: "IP" kalau ada A record, "" kalau kosong, dan DNSRC berisi status.
DNSRC=""
digA() {   # digA <domain> -> cetak IP pertama atau kosong; DNSRC=NOERROR/NXDOMAIN/REFUSED/SERVFAIL/TIMEOUT
    local out rc
    out="$(dig +time=5 +tries=1 "@$TARGET" "$1" A 2>&1)"; rc=$?
    # PENTING: '--' sebelum pattern. "->>HEADER<<-" diawali '-' dan tanpa '--'
    # grep membacanya sebagai opsi ("grep: invalid option -- '>'").
    if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | grep -q -- "->>HEADER<<-"; then
        DNSRC="TIMEOUT"; return 0
    fi
    # Ambil status via awk, bukan grep -oE: output dig berisi "->>HEADER<<-"
    # dan pola grep dengan '>' di dalamnya bisa salah di-parse sebagai opsi.
    DNSRC="$(printf '%s\n' "$out" | awk '/->>HEADER<<-/{for(i=1;i<=NF;i++) if($i=="status:"){print $(i+1); exit}}' | tr -d ',')"
    echo "$out" | awk '/^;; ANSWER SECTION:/{f=1;next} /^$/{f=0} f && $4=="A"{print $5; exit}'
}

echo "=== Verifikasi ZetDNS (target: $TARGET) ==="
echo

# ---------- 1. service ----------
echo "[1] Service"
if [ "$LOCAL" -eq 1 ]; then
    for u in dnstrust-unbound dnstrust-admin nginx; do
        # is-active mencetak "unknown" + exit 4 kalau unit TIDAK ADA.
        # Cek keberadaan lewat systemctl cat (tidak terpengaruh pipe/SIGPIPE
        # seperti list-unit-files | grep, yang bisa gagal palsu di dalam `if !`).
        if ! systemctl cat "$u" >/dev/null 2>&1; then
            bad "$u: unit TIDAK ADA (install belum selesai?)"
            info "cek: ls /etc/systemd/system/dnstrust* ; systemctl daemon-reload"
            [ "$u" = "dnstrust-unbound" ] && DNS_DEAD=1
        else
            state="$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
            if [ "$state" = "active" ]; then
                ok "$u: active"
            else
                bad "$u: $state"
                [ "$u" = "dnstrust-unbound" ] && DNS_DEAD=1
                # beri petunjuk akar masalah, bukan cuma status
                if [ "$u" = "dnstrust-unbound" ]; then
                    info "cek: journalctl -u dnstrust-unbound -n 30 --no-pager"
                    info "cek: /usr/local/sbin/unbound-checkconf 2>&1 | head"
                    info "cek: ldd /usr/local/sbin/unbound | grep -i 'not found'"
                    info "cek: ldconfig -p | grep libcdb"
                fi
            fi
        fi
    done
    # nginx yang "activating" tetap dianggap gagal
    failed="$(systemctl --failed --no-legend 2>/dev/null | grep -c '\.service' || true)"
    [ "$failed" -eq 0 ] && ok "tidak ada unit gagal" || bad "$failed unit gagal"
else
    info "(dilewati — bukan mode lokal)"
fi
echo

# Kalau resolver mati, SEMUA uji DNS di bawah tidak bermakna.
# Jangan cetak OK palsu: tandai LEWAT dan jelaskan kenapa.
if [ "$DNS_DEAD" -eq 1 ]; then
    echo "[2-4] Uji DNS — DILEWATI"
    skip "resolver mati: uji DNS tidak bisa dipercaya, perbaiki service dulu"
    info "OK palsu di sini dulu pernah menyesatkan — itu kenapa dilewati, bukan diluluskan"
    echo
else

# ---------- 2. ACL ----------
echo "[2] ACL terjangkau"
WHOAMI="$(digA whoami.akamai.net)"
if [ -n "$WHOAMI" ]; then
    ok "query diterima (status=$DNSRC): whoami.akamai.net -> $WHOAMI"
    info "kalau nilainya = IP publik server, berarti resolver benar-benar rekursif"
elif [ "$DNSRC" = "REFUSED" ]; then
    bad "query DITOLAK (status=REFUSED) — IP ini tidak masuk ACL"
    info "tambah jaringan di dashboard menu 'Client access', atau /etc/unbound/unbound.conf"
elif [ "$DNSRC" = "TIMEOUT" ]; then
    bad "tidak ada jawaban sama sekali (timeout) — resolver tidak listen / port tertutup"
    info "cek: ss -lunp | grep ':53 ' ; systemctl status dnstrust-unbound"
else
    bad "jawaban kosong (status=$DNSRC)"
fi
echo

# ---------- 3. blokir ----------
echo "[3] Domain blokir"
BLOCKED=0; CHECKED=0
for d in 0--0--1-com.pages.dev pornoxxxsexsatanic.blogspot.com; do
    CHECKED=$((CHECKED+1))
    ip="$(digA "$d")"
    if [ -n "$ip" ]; then
        ok "$d -> $ip"
        BLOCKED=$((BLOCKED+1))
    elif [ "$DNSRC" = "NXDOMAIN" ]; then
        # sah: domain memang tidak ada, bukan tanda resolver rusak
        skip "$d -> NXDOMAIN (domain tidak ada di daftar, itu wajar)"
    elif [ "$DNSRC" = "TIMEOUT" ] || [ "$DNSRC" = "REFUSED" ] || [ "$DNSRC" = "SERVFAIL" ]; then
        bad "$d -> gagal resolve (status=$DNSRC) — resolver bermasalah, bukan domainnya"
    else
        bad "$d -> kosong (status=$DNSRC) tanpa alasan jelas"
    fi
done
# kalau tak satu pun terblokir, CDB kemungkinan belum termuat
if [ "$BLOCKED" -eq 0 ] && [ "$CHECKED" -gt 0 ]; then
    bad "tidak ada domain terblokir sama sekali — CDB mungkin belum termuat"
    info "cek: ls -la /var/lib/dnstrust/blacklist.db ; systemctl start unbound-blacklist-update.service"
fi
echo

# ---------- 4. domain normal ----------
echo "[4] Domain normal tidak terblokir"
for d in cloudflare.com example.com; do
    ip="$(digA "$d")"
    if [ -n "$ip" ]; then
        ok "$d -> $ip"
    else
        bad "$d TIDAK resolve (status=$DNSRC) — resolver rusak atau domain terblokir keliru"
    fi
done
echo

fi   # akhir blok "resolver hidup"

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
