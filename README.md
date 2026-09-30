# ZetDNS-ISP — Komdigi Trust Positif DNS Filter + Laman Labuh

Instalasi produksi **ZetDNS** ([zet-dns](https://github.com/niammuddin/zet-dns)) di server ISP, lengkap dengan
**halaman blokir (laman labuh)** yang identik dengan `https://lamanlabuh.ispku.id/`.

Repo ini adalah **salinan penuh** dari instalasi yang sudah terbukti jalan di produksi
(2026-09-30, `49.0.27.27`, Debian 12, x86_64), jadi kamu bisa mereplikasinya di server
baru tanpa menebak-nebak konfigurasi.

---

## Daftar isi

- [Hasil terukur](#hasil-terukur)
- [Arsitektur](#arsitektur)
- [Persyaratan](#persyaratan)
- [Instalasi cepat](#instalasi-cepat)
- [Instalasi manual (langkah demi langkah)](#instalasi-manual-langkah-demi-langkah)
- [Konfigurasi ACL](#konfigurasi-acl)
- [Halaman blokir / laman labuh](#halaman-blokir--laman-labuh)
- [Operasi harian](#operasi-harian)
- [Troubleshooting](#troubleshooting)
- [Pitfalls](#pitfalls)
- [Keamanan](#keamanan)
- [Struktur repo](#struktur-repo)

---

## Hasil terukur

Angka nyata dari produksi, **9.752.802 domain** diblokir aktif:

| Metrik | Nilai |
|---|---|
| **Unbound RSS** (9,75 juta domain aktif) | **27,8 MB** |
| Total host terpakai | 55 MB dari 4 GB |
| CDB `blacklist.db` | 461 MB |
| `trust.txt` (daftar domain) | 218 MB |
| Waktu update (download + validasi + build) | **69 detik** |
| `blcreate` build CDB | 4 detik |
| QPS terukur | 1.440 (2 vCPU, santai) |
| Cache hit ratio | 92,1% |
| Latency median / rata-rata | 46 ms / 104 ms |
| Query timed out | 0 |

**Kenapa CDB begitu hemat:** zet-dns memakai Unbound yang dipatch dengan `filter-database:`
(format CDB, mmap read-only). Bandingkan dengan RPZ upstream:

| Metode | 500k domain | Ekstrapolasi 9,75 juta |
|---|---|---|
| RPZ (upstream Unbound) | 600 MB | ~11,7 GB — **gagal di 4 GB** |
| local-zone `always_nxdomain` | 53 MB / 100k | ~5,2 GB — **gagal** |
| **CDB `filter-database`** | — | **27,8 MB** — ✓ |

Rasio ~430x lebih hemat. Ini alasan utama zet-dns memakai binary sendiri,
bukan `apt install unbound`.

---

## Arsitektur

```
┌─────────────────────────────────────────────────────────────┐
│  Klien (pelanggan ISP)                                      │
│  DNS -> 10.0.0.53 / 49.0.27.27                              │
└──────────────────────────┬──────────────────────────────────┘
                           │ port 53
┌──────────────────────────▼──────────────────────────────────┐
│  Unbound 1.25.1 (patched)                                   │
│  module-config: respip validator iterator                   │
│                                                             │
│  domain blokir ──> CDB lookup (mmap) ──> A 49.0.27.27      │
│  domain normal ──> rekursi dari root (bukan forwarder)      │
│  google.* ──> CNAME forcesafesearch.google.com              │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTP (Host: domain-blokir)
┌──────────────────────────▼──────────────────────────────────┐
│  nginx :80 default_server (catch-all)                       │
│  -> /var/www/lamanlabuh/index.html                          │
│  Halaman "WEBSITE DIBLOKIR" KOMDIGI                         │
└─────────────────────────────────────────────────────────────┘

Komponen pendukung:
  dnstrust-admin    dashboard web HTTPS :9080
  unbound-blacklist-update.timer   sinkronisasi Komdigi tiap 60 menit
  dnstrust-tproxy-routing          policy routing TPROXY (opsional)
```

**Komponen dari repo asli (tidak ada di sini, ambil dari rilis upstream):**

Binary x86_64 berikut **harus** diambil dari [repo asli](https://github.com/niammuddin/zet-dns)
karena berisi patch `filter-database:` yang tidak ada di Unbound upstream:

```
/usr/local/sbin/unbound               (5,3 MB)
/usr/local/sbin/unbound-checkconf     (4,5 MB)
/usr/local/sbin/unbound-control       (4,5 MB)
/usr/local/sbin/dnstrust-admin        (12,7 MB)
/usr/local/sbin/update-dnstrust-blacklist  (script, 15 KB)
/usr/local/sbin/verify-dnstrust-hot-remap  (script, 3,8 KB)
src/bin/blcreate                      (builder CDB)
src/bin/libcdb.so.1                   (shared lib)
```

Yang **ada** di repo ini: `bin/dnstrust-control` (wrapper shell kecil, 97 B).

**Penting:** binary asli hanya untuk **x86_64**. Di arm64/aarch64,
`install-dns.sh` keluar dengan error:

```
unsupported architecture: aarch64; this release contains Linux amd64 binaries
```

Tidak ada source yang dirilis. Untuk arm64 kamu harus build Unbound dari source
dan mempatch `filter-database:` sendiri.

---

## Persyaratan

| Item | Nilai |
|---|---|
| **Arsitektur** | **x86_64** (wajib) |
| **OS** | Debian 12 bookworm |
| RAM | 2 GB cukup, 4 GB nyaman |
| Disk | 8 GB minimum (CDB 461 MB + trust.txt 218 MB + ruang rollback) |
| CPU | 2 vCPU |
| Virt | LXC privileged **atau** VM/bare metal |
| Outbound | port 53 UDP+TCP ke root/authoritative (harus tidak diblokir) |
| Inbound | port 53 dari jaringan pelanggan, port 80 untuk laman labuh |

**Catatan LXC:** harus privileged, karena installer menulis systemd unit dan
mengubah `systemd-resolved`.

**Paket yang dibutuhkan:**

```bash
apt-get update
apt-get install -y git curl ca-certificates nginx unbound-anchor
```

`unbound-anchor` untuk DNSSEC root trust anchor. `libunbound8` ikut otomatis —
tapi **tidak dipakai**; binary patched jalan sendiri dari `/usr/local/sbin`.

---

## Instalasi cepat

### 1. Siapkan server

```bash
apt-get update
apt-get install -y git curl ca-certificates nginx unbound-anchor
```

### 2. Clone repo asli + repo ini

```bash
git clone https://github.com/niammuddin/zet-dns /root/zet-dns
git clone <URL-repo-ini> /root/zetdns-isp
```

### 3. Jalankan installer zet-dns

`install.sh` meminta password dashboard lewat `stty -echo`, jadi butuh PTY:

```bash
cd /root/zet-dns
printf '%s\n' 'GANTI_PASSWORD_INI' | script -qec "./install.sh" /tmp/zetdns-install.log
echo "EXIT=$?"
```

Harus `EXIT=0` dalam beberapa detik.

### 4. Terapkan config dari repo ini

```bash
cd /root/zetdns-isp
sudo ./install-lamanlabuh.sh --dns-ip 10.0.0.53
```

Script ini:
- install nginx vhost `default_server` catch-all
- pasang halaman laman labuh ke `/var/www/lamanlabuh/index.html`
- set `lamanlabuh.conf` agar domain blokir diarahkan ke `--dns-ip`
- validasi + reload unbound dan nginx
- verifikasi end-to-end

### 5. Tarik daftar Komdigi pertama kali

```bash
systemctl start unbound-blacklist-update.service
journalctl -u unbound-blacklist-update -f
```

Tunggu ~70 detik. Tanda sukses:

```
blacklist activated: raw=9752845 active=9752802 rejected=43 duplicates=0
health check passed: 0--0--1-com.pages.dev -> 127.0.0.1
```

### 6. Verifikasi

```bash
# blokir -> IP server
dig @127.0.0.1 0--0--1-com.pages.dev A +short
# harus: <IP server>

# domain normal
dig @127.0.0.1 google.com A +short
# harus: IP Google asli, bukan IP server

# resolver rekursif sendiri (bukan forwarder)
dig @127.0.0.1 whoami.akamai.net A +short
# harus: IP publik server ini

# halaman blokir
curl -sS -H 'Host: situsblokir.com' http://127.0.0.1/ | grep -o '<title>[^<]*</title>'
# harus: <title>Landing Page Trustpositif</title>
```

---

## Instalasi manual (langkah demi langkah)

Kalau `install-lamanlabuh.sh` gagal, atau kamu ingin kontrol penuh:

### Langkah 1 — installer zet-dns

```bash
cd /root/zet-dns
printf '%s\n' 'PASSWORDMU' | script -qec "./install.sh" /tmp/zetdns-install.log
cat /tmp/zetdns-install.log | tr -d '\r' | grep -vE '^$' | tail -40
```

### Langkah 2 — matikan systemd-resolved (kalau ada)

```bash
systemctl disable --now systemd-resolved 2>/dev/null || true
```

### Langkah 3 — root trust anchor

```bash
unbound-anchor -a /var/lib/dnstrust/root.key 2>/dev/null || true
chown dnstrust:dnstrust /var/lib/dnstrust/root.key
```

### Langkah 4 — nginx + halaman laman labuh

```bash
mkdir -p /var/www/lamanlabuh
cp /root/zetdns-isp/lamanlabuh/index.html /var/www/lamanlabuh/index.html
chown -R www-data:www-data /var/www/lamanlabuh
chmod 755 /var/www/lamanlabuh
chmod 644 /var/www/lamanlabuh/index.html

# matikan default site bawaan supaya tidak bentrok default_server
rm -f /etc/nginx/sites-enabled/default

cp /root/zetdns-isp/config/nginx/lamanlabuh.conf /etc/nginx/sites-available/lamanlabuh
ln -sf /etc/nginx/sites-available/lamanlabuh /etc/nginx/sites-enabled/lamanlabuh

nginx -t
systemctl restart nginx     # restart, bukan reload — default_server baru butuh restart
```

### Langkah 5 — arahkan domain blokir ke IP server

```bash
IP=10.0.0.53   # ganti dengan IP server ini
sed -i "s|\"blacklist\. 60 IN A [0-9.]*\"|\"blacklist. 60 IN A $IP\"|" /etc/unbound/lamanlabuh.conf
cat /etc/unbound/lamanlabuh.conf
# harus: local-data: "blacklist. 60 IN A 10.0.0.53"

/usr/local/sbin/unbound-checkconf /etc/unbound/unbound.conf
/usr/local/sbin/unbound-control reload
```

### Langkah 6 — ACL

Lihat [Konfigurasi ACL](#konfigurasi-acl).

### Langkah 7 — tarik daftar Komdigi

```bash
systemctl start unbound-blacklist-update.service
journalctl -u unbound-blacklist-update -f
```

### Langkah 8 — verifikasi

```bash
dig @127.0.0.1 0--0--1-com.pages.dev A +short
curl -sS -H 'Host: situsblokir.com' http://127.0.0.1/ | grep -o '<title>[^<]*</title>'
```

---

## Konfigurasi ACL

ACL ada di `/etc/unbound/unbound.conf`, **tidak dikelola dashboard** — edit manual.
Default repo menolak semua kecuali jaringan privat:

```
access-control: 127.0.0.0/8 allow
access-control: 10.0.0.0/8 allow
access-control: 172.16.0.0/12 allow
access-control: 192.168.0.0/16 allow
access-control: 0.0.0.0/0 refuse
```

### Menambah jaringan

**Jangan** membuka `0.0.0.0/0 allow` — server jadi open resolver,
bahan DDoS amplification, dan IP-mu bisa masuk blocklist.

Tambahkan **hanya** jaringan yang kamu butuhkan, tepat **sebelum** baris `refuse`:

```
access-control: 103.180.118.0/23 allow
access-control: 203.0.113.0/24 allow      # contoh
access-control: 0.0.0.0/0 refuse          # harus tetap baris terakhir
```

Cara aman (script menggantikan baris sebelum `refuse`):

```bash
cp -a /etc/unbound/unbound.conf /root/unbound.conf.bak

# sisipkan tepat sebelum baris refuse
awk '/access-control: 0\.0\.0\.0\/0 refuse/ && !d { print "    access-control: 203.0.113.0/24 allow"; d=1 } { print }' \
    /etc/unbound/unbound.conf > /etc/unbound/unbound.conf.new
mv /etc/unbound/unbound.conf.new /etc/unbound/unbound.conf

/usr/local/sbin/unbound-checkconf /etc/unbound/unbound.conf
/usr/local/sbin/unbound-control reload
```

### Menghitung apakah IP masuk ACL

```bash
python3 - <<'EOF'
import ipaddress
nets = ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16",
        "103.180.118.0/23","103.19.78.0/23","49.0.26.0/23","103.55.252.0/23"]
ip = ipaddress.ip_address("203.0.113.10")   # ganti IP tes
for n in nets:
    print(f"{'ALLOW' if ip in ipaddress.ip_network(n) else '  -  '}  {n}")
EOF
```

### Memverifikasi dari luar

```bash
dig +time=6 +tries=1 @<IP-SERVER> whoami.akamai.net A
```

- `status: NOERROR` + nilai = IP server -> **lolos**
- `status: REFUSED` -> **tidak masuk ACL**

---

## Halaman blokir / laman labuh

`lamanlabuh/index.html` adalah **salinan byte-per-byte** dari
`https://lamanlabuh.ispku.id/`, dengan CSS Bootstrap **di-inline** supaya tidak
bergantung CDN.

Terverifikasi: render **pixel-perfect** identik dengan halaman asli
(`0 dari 2.205.024` pixel berbeda) dan **0 request eksternal**.

### Cara kerja

DNS tidak bisa melakukan redirect HTTP — DNS hanya mengembalikan alamat.
Jadi alurnya:

1. Domain blokir -> DNS balas `A <IP server>`
2. Browser membuka `http://domain-blokir` ke IP itu, dengan `Host: domain-blokir`
3. nginx `default_server` menangkap **semua** Host yang tidak dikenali
4. Menyajikan halaman "WEBSITE DIBLOKIR"

Kuncinya `default_server` + `server_name _;` — tanpa itu, request dengan Host
asing akan dapat 404, bukan halaman blokir.

### Keterbatasan HTTPS

Ini batas teknis yang tidak bisa diakali:

```
https://domain-blokir
  -> browser minta sertifikat untuk "domain-blokir"
  -> server memberi sertifikat lain / self-signed
  -> browser: "Not Secure" — halaman blokir TIDAK tampil sebelum user klik "lanjut"
```

Halaman blokir hanya andal untuk **HTTP**. Untuk HTTPS, pilihan ISP:

| Pendekatan | Hasil |
|---|---|
| Redirect HTTP saja (setup ini) | Warning hanya untuk situs HTTPS/HSTS |
| Blokir port 443 di router untuk domain blokir | Tidak ada warning, tapi tidak ada edukasi |
| Self-signed cert di :443 | Halaman tampil setelah user klik "lanjut" |
| NXDOMAIN | Domain tidak resolve sama sekali — paling bersih, tanpa edukasi |

### Memperbarui halaman

Halaman ini **statis**. Kalau `lamanlabuh.ispku.id` berubah, ambil ulang:

```bash
curl -sSL https://lamanlabuh.ispku.id/ -o /tmp/orig.html
# lalu inline-kan CSS-nya
```

---

## Operasi harian

### Service & timer

```bash
systemctl status dnstrust-unbound dnstrust-admin
systemctl list-timers unbound-blacklist-update.timer
```

Cadence default: `OnBootSec=10min`, lalu tiap 60 menit + jitter 5 menit.
Bisa diubah dari dashboard (menulis
`/etc/systemd/system/unbound-blacklist-update.timer.d/dashboard.conf`).

### Refresh manual

```bash
/usr/local/sbin/dnstrust-control refresh      # reload config unbound
systemctl start unbound-blacklist-update.service   # tarik ulang daftar
```

`dnstrust-control` subcommand yang tersedia:

```
refresh | stats | stats_noreset | status | uptime
```

**Tidak ada `reload`.** Untuk reload config pakai:

```bash
/usr/local/sbin/unbound-control reload
```

### Statistik

```bash
/usr/local/sbin/dnstrust-control stats_noreset | grep -E '^total\.num\.'
```

Angka penting:

```
total.num.queries            total query
total.num.cachehits          cache hit (harusnya >85%)
total.num.recursivereplies   rekursi ke root
total.num.queries_timed_out  harus 0
total.num.blacklist          jumlah query kena blokir
total.recursion.time.median  latency median (ms)
total.requestlist.avg        antrean — >100 = mulai sesak
```

### Monitoring beban

```bash
MP=$(systemctl show dnstrust-unbound -p MainPID --value)
ps -o rss=,pcpu= -p $MP | awk '{printf "RSS=%.1f MB CPU=%s%%\n", $1/1024, $2}'
```

**RSS naik dari 27 MB ke ~700 MB itu normal** — itu cache yang terisi, bukan
kebocoran. Akan plateau sesuai `msg-cache-size`.

### Hot-remap (update tanpa restart)

zet-dns memakai atomic rename + mmap, jadi update CDB **tidak** memutus layanan:

```bash
/usr/local/sbin/verify-dnstrust-hot-remap
```

Terverifikasi: PID sama, uptime lanjut, counter tidak reset.

---

## Troubleshooting

### `status: REFUSED` dari klien

IP klien tidak masuk ACL. Cek `access-control` di `/etc/unbound/unbound.conf`,
tambahkan jaringan klien, lalu `unbound-control reload`.

### Domain blokir balas `127.0.0.1` tapi browser bilang "can't connect"

`lamanlabuh.conf` masih menunjuk `127.0.0.1` — itu loopback **klien**, bukan
server. Ganti ke IP server:

```bash
cat /etc/unbound/lamanlabuh.conf
# harus: local-data: "blacklist. 60 IN A <IP-SERVER>"
```

### Halaman blokir balas "Welcome to nginx!"

Vhost `default_server` bawaan masih aktif. Hapus symlink-nya dan **restart**
(bukan reload):

```bash
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
```

### "Kenapa DNS ini forwarding ke Google?"

**Biasanya salah paham.** Kalau kamu query `google.com`, jawabannya memang
IP Google — karena `google.com` milik Google.

Cara membedakan resolver rekursif vs forwarder: tanya **`whoami.akamai.net`**,
bukan `google.com`.

```bash
dig @127.0.0.1 whoami.akamai.net A +short    # rekursif -> IP server ini
dig @8.8.8.8  whoami.akamai.net A +short     # forwarder -> IP Google
```

`forwarder.conf` isinya komentar semua secara default = rekursif murni.

### `dnstrust-control reload` -> "usage: ..."

Subcommand `reload` tidak ada. Pakai `/usr/local/sbin/unbound-control reload`.

### Dashboard "next scheduled check" tidak akurat

Dashboard menghitung `last + interval` naif, tidak menyertakan
`RandomizedDelaySec=5min` dan tidak sadar timer direset reboot. Untuk jadwal
sebenarnya:

```bash
systemctl list-timers unbound-blacklist-update.timer
```

Ini kosmetik, bukan bug fungsional.

### Update gagal / CDB tidak berubah

```bash
cat /var/lib/dnstrust/trust.lastcheck
journalctl -u unbound-blacklist-update -n 50
```

Updater punya pengaman: validasi sha256, rollback saat gagal, dan guard kalau
daftar menyusut >20%. Daftar lama tetap aktif saat validasi gagal — itu fitur,
bukan bug.

---

## Pitfalls

Hal-hal yang memakan waktu saat instalasi pertama:

1. **arm64 tidak didukung.** Binary hanya x86_64, tanpa source. Installer keluar
   di `install-dns.sh` baris 62-68. Tidak ada jalan pintas — QEMU/binfmt ditolak
   untuk produksi (lambat, mmap CDB crash).

2. **RPZ dan local-zone tidak cukup.** 9,75 juta domain butuh ~11,7 GB dengan RPZ,
   ~5,2 GB dengan local-zone. Hanya CDB yang muat. Jangan coba jalur lain.

3. **`install.sh` butuh PTY.** Pakai `script -qec` atau ekspektasi gagal di prompt
   password.

4. **nginx butuh `restart`, bukan `reload`**, saat mengubah `default_server`.
   Reload tidak mengganti vhost default.

5. **ACL tidak dikelola dashboard.** Edit manual + `unbound-checkconf` + reload.

6. **Klien harus diarahkan ke resolver.** Install di server tidak otomatis
   mengganti DNS pelanggan. Set lewat DHCP router/PPPoE pool.

7. **`resolv.conf` di LXC dikelola Proxmox.** Kalau di dalam CT terlihat penanda
   `# --- BEGIN PVE ---`, perubahan bisa hilang saat restart. Ubah permanen dari
   host: `pct set <vmid> --nameserver 127.0.0.1`.

8. **Dashboard bisa menimpa `lamanlabuh.conf`.** Menu "Block response" di
   dashboard menulis file yang sama. Kalau kamu simpan dari dashboard,
   konfigurasi manual bisa kembali ke `127.0.0.1`.

9. **Dashboard :9080 terbuka publik dengan self-signed cert.** Taruh di belakang
   nginx + Let's Encrypt, atau batasi firewall ke IP admin.

10. **Kredensial di chat/dokumen = bocor.** Ganti password root dan password
    dashboard setelah instalasi. Pakai SSH key, matikan login password.

---

## Keamanan

**Setelah instalasi selesai, lakukan ini:**

1. **Ganti password root** — installer tidak menyentuh ini.
2. **Matikan `PermitRootLogin` password**, pakai SSH key.
3. **Ganti password dashboard:**

   ```bash
   # dari dashboard UI, atau reset lewat config
   # password_hash di /etc/dnstrust-admin/config.json (pbkdf2-sha256)
   ```

4. **Batasi dashboard :9080** ke IP admin, atau taruh di belakang nginx + TLS
   yang valid:

   ```nginx
   server {
       listen 443 ssl;
       server_name dns-admin.contoh.id;
       ssl_certificate     /etc/letsencrypt/live/dns-admin.contoh.id/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/dns-admin.contoh.id/privkey.pem;
       location / { proxy_pass https://127.0.0.1:9080; proxy_ssl_verify off; }
   }
   ```

5. **Jangan pernah** `access-control: 0.0.0.0/0 allow`. Open resolver =
   bahan DDoS amplification. Kalau butuh tes cepat, pakai batas waktu dan
   rollback otomatis.

6. **File di repo ini sudah dibersihkan** — `config.json` (yang berisi
   `session_key` dan `password_hash`) **tidak** diikutkan. Regenerasi otomatis
   saat install.

---

## Struktur repo

```
.
├── README.md
├── install-lamanlabuh.sh          # installer laman labuh + wiring DNS
├── verify.sh                      # skrip verifikasi end-to-end
├── bin/
│   └── dnstrust-control            # wrapper kecil (97 B) dari instalasi nyata
├── config/
│   ├── unbound/
│   │   ├── unbound.conf            # config utama + ACL
│   │   ├── forwarder.conf          # rekursif murni (isinya komentar)
│   │   ├── hosts.conf
│   │   ├── lamanlabuh.conf         # local-data blokir -> IP server
│   │   ├── module-config.conf      # respip validator iterator
│   │   ├── safesearch.conf         # RPZ safesearch
│   │   ├── tproxy.conf             # TPROXY (disabled default)
│   │   └── whitelist.conf          # 56 domain whitelist
│   ├── systemd/
│   │   ├── dnstrust-unbound.service
│   │   ├── dnstrust-admin.service
│   │   ├── dnstrust-admin-collect.{service,timer}
│   │   ├── dnstrust-admin-worker.{path,service}
│   │   ├── dnstrust-tproxy-routing.service
│   │   ├── unbound-blacklist-update.{service,timer}
│   │   └── unbound-blacklist-update.timer.d/dashboard.conf
│   ├── nginx/
│   │   └── lamanlabuh.conf         # default_server catch-all
│   └── default/
│       └── unbound-blacklist-update
├── lamanlabuh/
│   └── index.html                  # halaman blokir KOMDIGI, CSS inline
└── docs/
    └── upstream-files.md           # file yang harus diambil dari repo asli
```

---

## Lisensi & kredit

- **zet-dns** — [niammuddin/zet-dns](https://github.com/niammuddin/zet-dns)
- **Halaman laman labuh** — salinan dari `https://lamanlabuh.ispku.id/`
  (© SmartDNS), dipakai sesuai konteks pemblokiran Komdigi.
- **Daftar domain** — Komdigi Trust Positif:
  `https://trustpositif.komdigi.go.id/assets/db/domains_isp`

Repo ini berisi konfigurasi instalasi, bukan karya orisinal. Binary tidak
disertakan — ambil dari repo upstream.
