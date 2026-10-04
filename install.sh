#!/bin/bash
#
# install.sh — installer lengkap ZetDNS (DNS filter Komdigi + laman labuh).
#
# Satu perintah, tanpa clone repo lain. Semua binary sudah ada di src/bin/.
#
# Pemakaian:
#   sudo ./install.sh --dashboard-password 'PASSWORD_KUAT' --block-ip 10.0.0.53
#   sudo ./install.sh                     # pakai IP deteksi otomatis
#
set -euo pipefail

DASH_PW=""
BLOCK_IP=""
DOC_ROOT="/var/www/lamanlabuh"
SKIP_DNS=0
SKIP_PAGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dashboard-password) DASH_PW="${2:-}"; shift 2 ;;
        --block-ip)           BLOCK_IP="${2:-}"; shift 2 ;;
        --document-root)      DOC_ROOT="${2:-}"; shift 2 ;;
        --skip-dns)           SKIP_DNS=1; shift ;;
        --skip-page)          SKIP_PAGE=1; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "argumen tidak dikenal: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -ne 0 ] && { echo "ERROR: jalankan sebagai root." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_BIN="$SCRIPT_DIR/src/bin"
SRC_SCRIPTS="$SCRIPT_DIR/src/scripts"
BACKUP_DIR="/root/zetdns-backups"
LOG="/tmp/zetdns-install-$(date +%Y%m%d-%H%M%S).log"

step()  { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }
ok()    { printf '    \033[32mOK\033[0m %s\n' "$1"; }
warn()  { printf '    \033[33m!\033[0m %s\n' "$1"; }
die()   { printf '\n\033[31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
bk() { [ -e "$1" ] || return 0; local t="$BACKUP_DIR/$(echo "$1" | tr '/' '_').before-install"
       [ -e "$t" ] || { cp -a "$1" "$t"; echo "    backup: $1"; }; }

echo "=== ZetDNS installer ==="
echo "  sumber   : $SCRIPT_DIR"
echo "  log      : $LOG"
echo "  tipe     : $(uname -m)"
echo

# ---------- 0. cek arsitektur ----------
step 0/9 "Cek arsitektur"
case "$(uname -m)" in
    x86_64|amd64) ok "x86_64" ;;
    *) die "binary hanya x86_64. Arsitekturmu: $(uname -m).
     Tidak ada source yang dirilis untuk arch lain.
     Lihat README bagian Pitfalls nomor 1." ;;
esac

# ---------- 0b. timezone ----------
# WAJIB paling awal. CT baru sering masih UTC, sehingga:
#   - journal/log updater bergeser 7 jam ("LAST SOURCE CHECK" di dashboard salah)
#   - NextElapseUSecRealtime / jadwal timer meleset
#   - masa berlaku sertifikat TLS tampak beda
# Setel sebelum paket/service apa pun dijalankan.
step 0/9 "Timezone"
if command -v timedatectl >/dev/null 2>&1; then
    CUR_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo '')"
    if [ "$CUR_TZ" != "Asia/Jakarta" ]; then
        timedatectl set-timezone Asia/Jakarta >>"$LOG" 2>&1 \
            || die "gagal set timezone Asia/Jakarta"
        ok "timezone: ${CUR_TZ:-tidak diketahui} -> Asia/Jakarta"
    else
        ok "timezone: Asia/Jakarta (sudah benar)"
    fi
    # tanpa tzdata, /etc/localtime tidak bisa di-resolve
    [ -e /usr/share/zoneinfo/Asia/Jakarta ] || \
        warn "tzdata Asia/Jakarta hilang; pasang paket tzdata"
else
    # fallback container tanpa systemd
    bk /etc/localtime
    ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime || \
        die "gagal menulis /etc/localtime"
    echo "Asia/Jakarta" > /etc/timezone
    ok "timezone: Asia/Jakarta (via /etc/localtime)"
fi
date "+    sekarang: %F %T %Z (%z)"

# ---------- 1. cek file sumber ----------
step 1/9 "Cek file sumber"
[ -d "$SRC_BIN" ] || die "$SRC_BIN tidak ada. Clone repo ini dengan lengkap."
for f in unbound unbound-control unbound-checkconf dnstrust-admin blcreate libcdb.so.1; do
    [ -f "$SRC_BIN/$f" ] || die "binary hilang: $SRC_BIN/$f"
done
ok "$(ls "$SRC_BIN" | wc -l) binary di src/bin"

# ---------- 2. paket sistem ----------
step 2/9 "Paket sistem"
export DEBIAN_FRONTEND=noninteractive
NEED=""
for p in nginx unbound-anchor curl ca-certificates; do
    dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"
done
if [ -n "$NEED" ]; then
    echo "    install:$NEED"
    apt-get update -qq >>"$LOG" 2>&1
    # shellcheck disable=SC2086
    apt-get install -y -qq $NEED >>"$LOG" 2>&1 || die "apt install gagal, lihat $LOG"
fi
ok "paket lengkap"

# ---------- 3. deteksi IP ----------
if [ -z "$BLOCK_IP" ]; then
    BLOCK_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [ -n "$BLOCK_IP" ] || BLOCK_IP="$(ip -4 addr show scope global | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
fi
[ -n "$BLOCK_IP" ] || die "tidak bisa deteksi IP. Pakai --block-ip <IP>."

# ---------- 4. user & direktori ----------
step 3/9 "User & direktori"
# DUA user terpisah, bukan satu. Jangan disatukan.
#   dnstrust        -> dipakai dnstrust-unbound.service (resolver)
#   dnstrust-admin  -> dipakai dnstrust-admin.service (dashboard)
# Kalau salah satu tidak ada atau salah owner, service gagal jalan.
for u in dnstrust dnstrust-admin; do
    if ! id "$u" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$u"
        ok "user $u dibuat"
    fi
done
mkdir -p /usr/local/sbin /usr/local/bin /usr/local/lib
mkdir -p /etc/unbound /var/lib/dnstrust /var/lib/dnstrust-admin /var/lib/zetdns
mkdir -p /etc/dnstrust-admin /etc/dnstrust-admin/tls

# Ownership PENTING: jangan chown -R ke satu user saja.
chown dnstrust:dnstrust /var/lib/dnstrust
chmod 750 /var/lib/dnstrust
chown root:dnstrust-admin /var/lib/dnstrust-admin
chmod 770 /var/lib/dnstrust-admin
for d in actions queue backups; do
    mkdir -p "/var/lib/dnstrust-admin/$d"
    chown root:dnstrust-admin "/var/lib/dnstrust-admin/$d"
    chmod 770 "/var/lib/dnstrust-admin/$d"
done
# metrics.db WAJIB ADA SEBELUM dnstrust-admin start.
#
# dnstrust-admin membuka DB dengan O_RDONLY (bukan O_CREAT) — dia TIDAK
# membuatnya sendiri. Kalau hilang, crash dengan pesan menyesatkan:
#   "buka database metrik: unable to open database file: out of memory (14)"
# Terjemahan sebenarnya: SQLITE_CANTOPEN karena ENOENT, BUKAN kehabisan RAM.
# Bukti strace:
#   open("/var/lib/dnstrust-admin/metrics.db", O_RDONLY|O_NOFOLLOW) = -1 ENOENT
#
# Seed dengan skema persis yang diharapkan dashboard (4 tabel + WAL).
if [ ! -s /var/lib/dnstrust-admin/metrics.db ]; then
    python3 - <<'PY' >>"$LOG" 2>&1
import sqlite3
c = sqlite3.connect("/var/lib/dnstrust-admin/metrics.db")
c.executescript("""
CREATE TABLE IF NOT EXISTS metric_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS metrics_raw (
    at INTEGER PRIMARY KEY,
    sample BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS metrics_hourly (
    at INTEGER PRIMARY KEY,
    sample BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS metrics_daily (
    at INTEGER PRIMARY KEY,
    sample BLOB NOT NULL
);
""")
c.execute("PRAGMA journal_mode=WAL")
c.commit(); c.close()
PY
    ok "metrics.db di-seed (schema: metric_meta, metrics_raw, metrics_hourly, metrics_daily)"
else
    ok "metrics.db sudah ada"
fi
for f in metrics.db metrics.db-shm metrics.db-wal; do
    if [ -e "/var/lib/dnstrust-admin/$f" ]; then
        chown root:dnstrust-admin "/var/lib/dnstrust-admin/$f"
        chmod 640 "/var/lib/dnstrust-admin/$f"
    fi
done
ok "direktori siap (dnstrust + dnstrust-admin)"

# ---------- 5. pasang binary ----------
if [ "$SKIP_DNS" -eq 0 ]; then
    step 4/9 "Pasang binary"
    for b in unbound unbound-control unbound-checkconf; do
        install -m 0755 "$SRC_BIN/$b" /usr/local/sbin/$b
    done
    install -m 0755 "$SRC_BIN/dnstrust-admin" /usr/local/sbin/dnstrust-admin
    install -m 0644 "$SRC_BIN/libcdb.so.1" /usr/local/lib/libcdb.so.1
    install -m 0755 "$SRC_BIN/blcreate" /usr/local/sbin/blcreate

    # script pendukung
    install -m 0755 "$SRC_SCRIPTS/dnstrust-control" /usr/local/sbin/dnstrust-control
    install -m 0755 "$SRC_SCRIPTS/update-blacklist.sh" /usr/local/sbin/update-dnstrust-blacklist
    install -m 0755 "$SRC_SCRIPTS/verify-dnstrust-hot-remap" /usr/local/sbin/verify-dnstrust-hot-remap

    # WAJIB: /usr/local/libexec/dnstrust-unbound
    # update-dnstrust-blacklist memanggil ini untuk hook refresh ("runuser: failed to
    # execute /usr/local/libexec/dnstrust-unbound: No such file or directory").
    # Kalau hilang, updater gagal dengan "rollback unavailable: refresh failed".
    install -d -m 0755 /usr/local/libexec
    install -m 0755 "$SRC_SCRIPTS/dnstrust-unbound" /usr/local/libexec/dnstrust-unbound

    ldconfig
    ok "6 binary + 4 script terpasang (termasuk libexec/dnstrust-unbound)"

    # verifikasi patch CDB benar-benar ada
    if strings /usr/local/sbin/unbound 2>/dev/null | grep -q filter-database; then
        ok "patch filter-database: ADA"
    else
        warn "patch filter-database TIDAK terdeteksi — CDB tidak akan terbaca!"
    fi
    V="$(/usr/local/sbin/unbound -V 2>&1 | head -1)"
    ok "versi: $V"
else
    step 4/9 "Pasang binary"
    warn "dilewati (--skip-dns)"
fi

# ---------- 6. root trust anchor ----------
if [ "$SKIP_DNS" -eq 0 ]; then
    step 5/9 "DNSSEC trust anchor"
    if [ ! -s /var/lib/dnstrust/root.key ]; then
        unbound-anchor -a /var/lib/dnstrust/root.key >>"$LOG" 2>&1 || \
            warn "unbound-anchor gagal, DNSSEC mungkin tidak jalan"
    fi
    [ -s /var/lib/dnstrust/root.key ] && ok "root.key ada" || warn "root.key kosong"
    chown dnstrust:dnstrust /var/lib/dnstrust/root.key 2>/dev/null || true

    # Dummy CDB WAJIB ada SEBELUM unbound start. Tanpa file ini unbound crash:
    #   error: cannot open filter-database /var/lib/dnstrust/blacklist.db
    #   fatal error: Could not initialize main thread
    # lalu Restart=on-failure tiap 2 detik. Updater unit Requires=unbound, jadi
    # tiap restart unbound mengirim SIGTERM ke updater (exit 143) — CDB Komdigi
    # tidak pernah selesai diunduh. Pola upstream install-dns.sh: seed 1 domain.
    if [ ! -s /var/lib/dnstrust/blacklist.db ]; then
        printf '%s\n' seed.invalid > /var/lib/dnstrust/trust.txt
        ( cd /var/lib/dnstrust && /usr/local/sbin/blcreate < trust.txt ) >>"$LOG" 2>&1 \
            || die "gagal seed dummy blacklist.db (blcreate)"
        chown dnstrust:dnstrust /var/lib/dnstrust/trust.txt /var/lib/dnstrust/blacklist.db
        chmod 0644 /var/lib/dnstrust/blacklist.db
        ok "dummy blacklist.db ($(stat -c%s /var/lib/dnstrust/blacklist.db) B) — unbound bisa start"
        warn "ini BUKAN daftar Komdigi. Wajib: systemctl start unbound-blacklist-update.service"
    else
        ok "blacklist.db sudah ada ($(du -h /var/lib/dnstrust/blacklist.db | cut -f1))"
    fi
else
    step 5/9 "DNSSEC trust anchor"; warn "dilewati"
fi

# ---------- 7. config ----------
if [ "$SKIP_DNS" -eq 0 ]; then
    step 6/9 "Pasang config unbound & systemd"
    # SEMUA file di config/unbound, bukan cuma *.conf.
    # rpz.safesearch TIDAK berekstensi .conf — kalau dilewatkan, safesearch.conf
    # menunjuk zonefile yang tidak ada, dan unbound mati dengan
    # "fatal error: Could not setup authority zones" (restart loop).
    for f in "$SCRIPT_DIR"/config/unbound/*; do
        [ -f "$f" ] || continue
        n="$(basename "$f")"
        # source policy milik dashboard, bukan zonefile unbound
        case "$n" in *.source) continue ;; esac
        bk "/etc/unbound/$n"
        install -m 0644 "$f" "/etc/unbound/$n"
    done
    ok "$(ls -1 "$SCRIPT_DIR"/config/unbound/ | wc -l) file config unbound"

    # rpz.safesearch harus ada SEBELUM dashboard boleh menyalakan SafeSearch.
    # Kalau tidak ada, buat zone kosong yang valid (SOA + NS) sebagai jaring
    # pengaman supaya dashboard tidak bisa mematikan unbound.
    RPZ=/etc/unbound/rpz.safesearch
    if [ ! -s "$RPZ" ]; then
        cat > "$RPZ" <<'RPZEOF'
$TTL 128
;$ORIGIN rpz.safesearch
@               IN  SOA localhost.        root.localhost. (
                1 ; serial
                1d ; refresh
                2h ; retry
                4w ; expire
                1h ; default_ttl
                )
                NS localhost.
RPZEOF
        warn "rpz.safesearch dibuat kosong (SafeSearch belum punya entri)"
    fi
    chown root:dnstrust-admin "$RPZ" 2>/dev/null || true
    chmod 644 "$RPZ"
    ok "rpz.safesearch siap ($(stat -c%s "$RPZ") B)"

    # Source policy (google/bing/duckduckgo/yandex) WAJIB di
    # /var/lib/dnstrust-admin/rpz.safesearch.source. Dashboard Apply
    # SafeSearch validasi tiap engine yang dicentang punya komentar
    # "; force <engine> safesearch" + rewrite. Stub SOA di zonefile
    # TIDAK cukup — error:
    #   source RPZ SafeSearch tidak memiliki policy untuk bing
    # Pola upstream install-dashboard.sh: salin artifact kalau source
    # belum berisi "; force .* safesearch".
    SRC_DST=/var/lib/dnstrust-admin/rpz.safesearch.source
    SRC_REPO="$SCRIPT_DIR/config/dnstrust-admin/rpz.safesearch.source"
    if ! grep -q '^; force .* safesearch' "$SRC_DST" 2>/dev/null; then
        [ -s "$SRC_REPO" ] || die "artifact hilang: $SRC_REPO"
        install -o root -g dnstrust-admin -m 0640 "$SRC_REPO" "$SRC_DST"
        ok "rpz.safesearch.source ($(wc -l < "$SRC_DST") baris, policy bing/google/ddg/yandex)"
    else
        ok "rpz.safesearch.source sudah berisi policy"
    fi

    # arahkan domain blokir ke IP ini
    bk /etc/unbound/lamanlabuh.conf
    sed -i -E "s|\"blacklist\. 60 IN A [0-9.]+\"|\"blacklist. 60 IN A $BLOCK_IP\"|" \
        /etc/unbound/lamanlabuh.conf
    ok "halaman blokir -> $BLOCK_IP"

    for f in "$SCRIPT_DIR"/config/systemd/*.service "$SCRIPT_DIR"/config/systemd/*.timer "$SCRIPT_DIR"/config/systemd/*.path; do
        [ -e "$f" ] || continue
        n="$(basename "$f")"
        bk "/etc/systemd/system/$n"
        install -m 0644 "$f" "/etc/systemd/system/$n"
    done
    if [ -d "$SCRIPT_DIR/config/systemd/unbound-blacklist-update.timer.d" ]; then
        mkdir -p /etc/systemd/system/unbound-blacklist-update.timer.d
        install -m 0644 "$SCRIPT_DIR"/config/systemd/unbound-blacklist-update.timer.d/*.conf \
            /etc/systemd/system/unbound-blacklist-update.timer.d/ 2>/dev/null || true
    fi
    bk /etc/default/unbound-blacklist-update
    install -m 0644 "$SCRIPT_DIR/config/default/unbound-blacklist-update" \
        /etc/default/unbound-blacklist-update
    ok "unit systemd terpasang"

    systemctl daemon-reload
    ok "daemon-reload"
else
    step 6/9 "Pasang config unbound & systemd"; warn "dilewati (--skip-dns)"
fi

# ---------- 8. laman labuh ----------
if [ "$SKIP_PAGE" -eq 0 ]; then
    step 7/9 "Laman labuh (halaman blokir)"
    mkdir -p "$DOC_ROOT"
    bk "$DOC_ROOT/index.html"
    install -m 0644 "$SCRIPT_DIR/lamanlabuh/index.html" "$DOC_ROOT/index.html"
    chown -R www-data:www-data "$DOC_ROOT" 2>/dev/null || true
    chmod 755 "$DOC_ROOT"
    ok "index.html ($(stat -c '%s bytes' "$DOC_ROOT/index.html"))"

    [ -e /etc/nginx/sites-enabled/default ] && {
        bk /etc/nginx/sites-enabled/default
        rm -f /etc/nginx/sites-enabled/default
        ok "default site bawaan dimatikan"
    }
    bk /etc/nginx/sites-available/lamanlabuh
    install -m 0644 "$SCRIPT_DIR/config/nginx/lamanlabuh.conf" \
        /etc/nginx/sites-available/lamanlabuh
    [ "$DOC_ROOT" != "/var/www/lamanlabuh" ] && \
        sed -i "s|root /var/www/lamanlabuh;|root $DOC_ROOT;|" \
            /etc/nginx/sites-available/lamanlabuh
    ln -sf /etc/nginx/sites-available/lamanlabuh /etc/nginx/sites-enabled/lamanlabuh

    nginx -t >>"$LOG" 2>&1 || die "nginx config tidak valid. Lihat $LOG"
    systemctl restart nginx
    ok "nginx restart (default_server catch-all)"
else
    step 7/9 "Laman labuh"; warn "dilewati (--skip-page)"
fi

# ---------- 9. password dashboard + start ----------
if [ "$SKIP_DNS" -eq 0 ]; then
    step 8/9 "Password dashboard & start service"
    if [ -n "$DASH_PW" ]; then
        [ ${#DASH_PW} -ge 12 ] || die "password dashboard minimal 12 karakter."

        # Sertifikat self-signed untuk HTTPS.
        # PENTING: kalau config.json menunjuk cert yang tidak ada, dnstrust-admin
        # crash: "open /etc/dnstrust-admin/tls/server.crt: no such file or
        # directory". Dan tanpa cert, dashboard cuma HTTP -- akses https://<ip>:9080
        # gagal dengan code=000 (tidak ada TLS listener), mudah disalahartikan
        # sebagai firewall.
        TLS=/etc/dnstrust-admin/tls
        if [ ! -s "$TLS/server.crt" ] || [ ! -s "$TLS/server.key" ]; then
            command -v openssl >/dev/null || apt-get install -y openssl >>"$LOG" 2>&1 || \
                die "openssl diperlukan untuk HTTPS dashboard"
            install -d -o root -g dnstrust-admin -m 0750 "$TLS"
            # SAN wajib memuat IP ini, kalau tidak browser tolak tanpa opsi paksa
            openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
                -keyout "$TLS/server.key" -out "$TLS/server.crt" \
                -subj "/CN=dns-admin" \
                -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:$BLOCK_IP" \
                >>"$LOG" 2>&1 || die "gagal membuat sertifikat TLS"
            chown root:dnstrust-admin "$TLS/server.crt" "$TLS/server.key"
            chmod 644 "$TLS/server.crt"; chmod 640 "$TLS/server.key"
            ok "sertifikat TLS dibuat (CN=dns-admin, SAN 127.0.0.1 + $BLOCK_IP)"
        else
            ok "sertifikat TLS sudah ada"
        fi

        # hash pbkdf2-sha256 sesuai format dnstrust-admin
        HASH="$(python3 - "$DASH_PW" <<'PY'
import hashlib, base64, secrets, sys
pw = sys.argv[1].encode()
salt = secrets.token_bytes(16)
dk = hashlib.pbkdf2_hmac("sha256", pw, salt, 310000)
b64 = lambda b: base64.b64encode(b).decode().rstrip("=")
print(f"pbkdf2-sha256$310000${b64(salt)}${b64(dk)}")
PY
)"
        CFG=/etc/dnstrust-admin/config.json
        # dnstrust-admin TIDAK membuat config.json sendiri. Tanpa file ini dia
        # langsung crash: "open /etc/dnstrust-admin/config.json: no such file
        # or directory" lalu restart loop. Wajib dibuat dari template.
        if [ ! -s "$CFG" ]; then
            TPL="$SCRIPT_DIR/config/dnstrust-admin/config.json.template"
            [ -s "$TPL" ] || die "template config.json tidak ada: $TPL"
            install -o root -g dnstrust-admin -m 0640 "$TPL" "$CFG"
            ok "config.json dibuat dari template"
        else
            bk "$CFG"
        fi
        python3 - "$CFG" "$HASH" <<'PY'
import json, secrets, base64, sys
p, h = sys.argv[1], sys.argv[2]
c = json.load(open(p))
c["password_hash"] = h
# session_key wajib acak per instalasi; template memakai placeholder
sk = c.get("session_key", "")
if not sk or sk.startswith("SET_"):
    c["session_key"] = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
# template tls_* kosong. Cert sudah dibuat di atas — tanpa path ini dashboard
# listen HTTP saja, https://:9080 = code=000 (bukan firewall).
if not c.get("tls_cert_file"):
    c["tls_cert_file"] = "/etc/dnstrust-admin/tls/server.crt"
if not c.get("tls_key_file"):
    c["tls_key_file"] = "/etc/dnstrust-admin/tls/server.key"
json.dump(c, open(p, "w"), indent=2)
PY
        chown root:dnstrust-admin "$CFG"
        chmod 0640 "$CFG"
        ok "password dashboard + session_key di-set"
    else
        warn "tidak ada --dashboard-password; dashboard pakai hash placeholder (tidak bisa login)"
        info "jalankan ulang: sudo ./install.sh --dashboard-password 'PASSWORD'"
    fi

    systemctl disable --now systemd-resolved 2>/dev/null || true

    FAILED=0
    for u in dnstrust-unbound dnstrust-admin; do
        systemctl enable "$u" >>"$LOG" 2>&1 || true
        systemctl restart "$u" >>"$LOG" 2>&1 || true
    done

    # Timer + path WAJIB di-enable, kalau tidak:
    #   - dashboard bilang "Needs attention", metrik kosong ("Waiting for
    #     historical samples"), semua kartu menampilkan "--"
    #   - aksi dari UI tidak pernah diterapkan (worker.path yang memicunya)
    # Keduanya adalah unit terpisah dari dnstrust-admin.service — meng-enable
    # service utamanya saja TIDAK cukup.
    for u in dnstrust-admin-collect.timer dnstrust-admin-worker.path; do
        if [ -f "/etc/systemd/system/$u" ]; then
            systemctl enable --now "$u" >>"$LOG" 2>&1 || true
            s="$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
            if [ "$s" = "active" ]; then
                ok "$u: active"
            else
                warn "$u: $s (metrik dashboard tidak akan terisi)"
                FAILED=1
            fi
        fi
    done

    # isi sampel pertama sekarang, jangan tunggu timer 1 menit
    /usr/local/sbin/dnstrust-admin collect >>"$LOG" 2>&1 || true

    # tunggu sampai stabil (dnstrust-admin butuh waktu buka metrics.db)
    for i in $(seq 1 20); do
        sleep 1
        a="$(systemctl is-active dnstrust-unbound 2>/dev/null || true)"
        b="$(systemctl is-active dnstrust-admin 2>/dev/null || true)"
        [ "$a" = "active" ] && [ "$b" = "active" ] && break
    done

    for u in dnstrust-unbound dnstrust-admin; do
        s="$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
        if [ "$s" = "active" ]; then
            ok "$u: active"
        else
            warn "$u: $s"
            FAILED=1
            echo "      ---- 8 baris log terakhir ----" >&2
            journalctl -u "$u" -n 8 --no-pager 2>&1 | sed 's/^/      /' >&2
        fi
    done

    # dashboard harus benar-benar merespons
    if [ "$FAILED" -eq 0 ]; then
        CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
                https://127.0.0.1:9080/ 2>/dev/null || echo 000)"
        case "$CODE" in
            200|301|302|303) ok "dashboard merespons (http=$CODE)" ;;
            *) warn "dashboard http=$CODE (harusnya 2xx/3xx)"
               FAILED=1
               journalctl -u dnstrust-admin -n 8 --no-pager 2>&1 | sed 's/^/      /' >&2 ;;
        esac
    fi

    if [ "$FAILED" -ne 0 ]; then
        echo
        echo "  \033[31mSERVICE GAGAL JALAN.\033[0m Penyebab paling sering:" >&2
        echo "    1. 'cannot open filter-database ... blacklist.db'" >&2
        echo "       -> dummy CDB belum ada. Seed lalu start updater:" >&2
        echo "         printf seed.invalid > /var/lib/dnstrust/trust.txt" >&2
        echo "         (cd /var/lib/dnstrust && blcreate < trust.txt)" >&2
        echo "         systemctl restart dnstrust-unbound" >&2
        echo "         systemctl start unbound-blacklist-update.service" >&2
        echo "    2. 'buka database metrik: ... out of memory (14)'" >&2
        echo "       -> SQLITE_CANTOPEN, OWNERSHIP salah, bukan RAM habis:" >&2
        echo "         chown root:dnstrust-admin /var/lib/dnstrust-admin/metrics.db*" >&2
        echo "         chmod 640 /var/lib/dnstrust-admin/metrics.db*" >&2
        echo "         systemctl restart dnstrust-admin" >&2
        echo "    Log lengkap: $LOG" >&2
    fi

    systemctl enable --now unbound-blacklist-update.timer >>"$LOG" 2>&1 || true
    ok "timer updater aktif"
else
    step 8/9 "Password dashboard & start service"; warn "dilewati (--skip-dns)"
fi

# ---------- ringkasan ----------
step 9/9 "Selesai"
echo
echo "  Halaman blokir : http://$BLOCK_IP/"
echo "  Dashboard      : https://$BLOCK_IP:9080/"
echo "  Backup         : $BACKUP_DIR"
echo "  Log            : $LOG"
echo
echo "LANGKAH BERIKUTNYA (wajib):"
echo "  1. Tarik daftar Komdigi pertama kali (~70 detik):"
echo "       systemctl start unbound-blacklist-update.service"
echo "       journalctl -u unbound-blacklist-update -f"
echo
echo "  2. Verifikasi:"
echo "       sudo ./verify.sh"
echo
echo "  3. Buka dashboard, menu 'Client access', tambahkan jaringan pelanggan."
echo "     JANGAN buka 0.0.0.0/0 allow."
echo
echo "  4. Arahkan DNS pelanggan ke $BLOCK_IP (DHCP / PPPoE pool)."
echo
echo "  5. Ganti password root, dan pasang SSH key."
echo
