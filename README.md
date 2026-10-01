# ZetDNS-ISP — Komdigi Trust Positif DNS Filter + Laman Labuh

Instalasi produksi **ZetDNS** ([zet-dns](https://github.com/niammuddin/zet-dns)) di server ISP, lengkap dengan
**halaman blokir (laman labuh)** yang identik dengan `https://lamanlabuh.ispku.id/`.

Repo ini adalah **salinan penuh** — konfigurasi **dan binary** sudah disertakan.
Satu `git clone`, tidak perlu mengambil apa pun dari repo lain.

Cukup 27 MB (binary 26 MB + config).

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

Satu perintah. Repo ini sudah berisi binary, jadi tidak perlu clone repo lain.

```bash
git clone https://github.com/alifiandzaki131103-rgb/zetdns-isp /root/zetdns-isp
cd /root/zetdns-isp
sudo ./install.sh --dashboard-password 'PASSWORD_KUAT_MIN_12_KARAKTER'
```

Installer mengerjakan semuanya: pasang binary, config, systemd unit, halaman
blokir, nginx, nyalakan service — lalu **memverifikasi bahwa dashboard
benar-benar merespons** (`OK dashboard merespons (http=303)`).

Setelah itu **wajib** dua langkah:

```bash
# 1. tarik daftar Komdigi pertama kali (~70 detik, CDB 461 MB)
sudo systemctl start unbound-blacklist-update.service
sudo journalctl -u unbound-blacklist-update -f

# 2. verifikasi end-to-end (16 pemeriksaan)
sudo ./verify.sh
```

Hasil yang diharapkan:

```
LULUS: 16   GAGAL: 0
SEMUA BAIK
```

Terakhir, arahkan DNS pelanggan ke IP server (DHCP/PPPoE pool), lalu tambahkan
jaringan pelanggan di dashboard → menu **Client access**.

### Opsi installer

| Opsi | Guna |
|---|---|
| `--dashboard-password 'X'` | Set password dashboard (min 12 karakter) |
| `--block-ip 10.0.0.53` | IP tujuan halaman blokir (default: deteksi otomatis) |
| `--document-root /path` | Lokasi halaman blokir (default `/var/www/lamanlabuh`) |
| `--skip-dns` | Hanya halaman blokir, jangan sentuh DNS |
| `--skip-page` | Hanya DNS, jangan pasang halaman blokir |

Semua file yang ditimpa dibackup ke `/root/zetdns-backups/` sebelum diubah.
Installer **idempoten** — aman dijalankan berulang.

---

## Instalasi manual (langkah demi langkah)

Kalau `install.sh` gagal, atau kamu ingin kontrol penuh:

### Langkah 1 — cek arsitektur

```bash
uname -m    # harus x86_64
```

Binary di repo ini **hanya x86_64**. Tidak ada rilis untuk arm64.

### Langkah 2 — pasang binary

```bash
cd /root/zetdns-isp
sudo install -m 0755 src/bin/unbound            /usr/local/sbin/unbound
sudo install -m 0755 src/bin/unbound-control    /usr/local/sbin/unbound-control
sudo install -m 0755 src/bin/unbound-checkconf  /usr/local/sbin/unbound-checkconf
sudo install -m 0755 src/bin/dnstrust-admin     /usr/local/sbin/dnstrust-admin
sudo install -m 0644 src/bin/libcdb.so.1        /usr/local/lib/libcdb.so.1
sudo install -m 0755 src/bin/blcreate           /usr/local/bin/blcreate
sudo install -m 0755 src/scripts/dnstrust-control /usr/local/sbin/dnstrust-control
sudo install -m 0755 src/scripts/update-blacklist.sh /usr/local/sbin/update-dnstrust-blacklist
sudo install -m 0755 src/scripts/verify-dnstrust-hot-remap /usr/local/sbin/verify-dnstrust-hot-remap
sudo ldconfig

# bukti patch CDB ada (WAJIB — tanpa ini CDB tidak terbaca)
strings /usr/local/sbin/unbound | grep -c filter-database    # harus > 0
/usr/local/sbin/unbound -V | head -1
```

### Langkah 3 — user, group, dan ownership

**Ini bagian paling mudah salah.** Ada **dua** user terpisah:

| User | Dipakai oleh | Direktori |
|---|---|---|
| `dnstrust` | `dnstrust-unbound.service` | `/var/lib/dnstrust` |
| `dnstrust-admin` | `dnstrust-admin.service` | `/var/lib/dnstrust-admin` |

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin dnstrust 2>/dev/null || true
sudo useradd --system --no-create-home --shell /usr/sbin/nologin dnstrust-admin 2>/dev/null || true

sudo mkdir -p /var/lib/dnstrust /var/lib/dnstrust-admin/{actions,queue,backups}

sudo chown dnstrust:dnstrust        /var/lib/dnstrust
sudo chmod 750                      /var/lib/dnstrust
sudo chown root:dnstrust-admin      /var/lib/dnstrust-admin
sudo chmod 770                      /var/lib/dnstrust-admin
sudo chown -R root:dnstrust-admin   /var/lib/dnstrust-admin/
sudo chmod -R 770                   /var/lib/dnstrust-admin/actions \
                                    /var/lib/dnstrust-admin/queue \
                                    /var/lib/dnstrust-admin/backups
```

### Langkah 4 — matikan systemd-resolved (kalau ada)

```bash
systemctl disable --now systemd-resolved 2>/dev/null || true
```

### Langkah 5 — root trust anchor

```bash
unbound-anchor -a /var/lib/dnstrust/root.key 2>/dev/null || true
chown dnstrust:dnstrust /var/lib/dnstrust/root.key
```

### Langkah 6 — config + systemd unit

```bash
cd /root/zetdns-isp
sudo cp config/unbound/*.conf          /etc/unbound/
sudo cp config/systemd/*.service       /etc/systemd/system/
sudo cp config/systemd/*.timer         /etc/systemd/system/
sudo cp config/systemd/*.path          /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/unbound-blacklist-update.timer.d
sudo cp config/systemd/unbound-blacklist-update.timer.d/*.conf \
        /etc/systemd/system/unbound-blacklist-update.timer.d/
sudo cp config/default/unbound-blacklist-update /etc/default/unbound-blacklist-update
sudo systemctl daemon-reload
```

### Langkah 7 — nginx + halaman laman labuh

```bash
sudo mkdir -p /var/www/lamanlabuh
sudo cp /root/zetdns-isp/lamanlabuh/index.html /var/www/lamanlabuh/index.html
sudo chown -R www-data:www-data /var/www/lamanlabuh
sudo chmod 755 /var/www/lamanlabuh
sudo chmod 644 /var/www/lamanlabuh/index.html

# matikan default site bawaan supaya tidak bentrok default_server
sudo rm -f /etc/nginx/sites-enabled/default

sudo cp /root/zetdns-isp/config/nginx/lamanlabuh.conf /etc/nginx/sites-available/lamanlabuh
sudo ln -sf /etc/nginx/sites-available/lamanlabuh /etc/nginx/sites-enabled/lamanlabuh

sudo nginx -t
sudo systemctl restart nginx     # restart, bukan reload — default_server baru butuh restart
```

### Langkah 8 — arahkan domain blokir ke IP server

**Cara 1 — dashboard (disarankan):** login, buka menu **Block page**, isi IP server,
simpan. Dashboard menulis `lamanlabuh.conf` dan reload unbound sendiri.

**Cara 2 — manual:**

```bash
IP=10.0.0.53   # ganti dengan IP server ini
sed -i "s|\"blacklist\. 60 IN A [0-9.]*\"|\"blacklist. 60 IN A $IP\"|" /etc/unbound/lamanlabuh.conf
cat /etc/unbound/lamanlabuh.conf
# harus: local-data: "blacklist. 60 IN A 10.0.0.53"

/usr/local/sbin/unbound-checkconf /etc/unbound/unbound.conf
/usr/local/sbin/unbound-control reload
```

### Langkah 9 — ACL

Lihat [Konfigurasi ACL](#konfigurasi-acl).

### Langkah 10 — tarik daftar Komdigi

```bash
systemctl start unbound-blacklist-update.service
journalctl -u unbound-blacklist-update -f
```

### Langkah 11 — verifikasi

```bash
dig @127.0.0.1 0--0--1-com.pages.dev A +short
curl -sS -H 'Host: situsblokir.com' http://127.0.0.1/ | grep -o '<title>[^<]*</title>'
```

---

## Konfigurasi ACL

ACL tersimpan di `/etc/unbound/unbound.conf`. **Dikelola dari dashboard** —
menu **Client access** (judul halaman: *Recursive clients*, overline: *Network access*).

| Cara | Kapan dipakai |
|---|---|
| **Dashboard → Client access** | Cara normal. Validasi CIDR, backup, apply, rollback otomatis |
| **Edit manual** `unbound.conf` | Dashboard mati, atau perubahan massal lewat skrip |

Dashboard membaca seluruh baris `access-control` dari `unbound.conf`, menampilkan
sebagai daftar jaringan, dan menulis ulang saat kamu simpan. Ada validasi
("ACL %q bukan IP/CIDR valid", maks 100 jaringan) dan rollback kalau reload gagal
("reload dashboard gagal; konfigurasi lama dipulihkan").

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

**Cara 1 — dashboard (disarankan):** login ke `https://<IP>:9080`, buka
**Client access**, tambah CIDR, simpan. Dashboard memvalidasi, membackup, apply,
dan rollback kalau gagal. Maks 100 jaringan, format IPv4/CIDR.

**Cara 2 — manual**, kalau dashboard tidak bisa dipakai. Tambahkan **hanya**
jaringan yang kamu butuhkan, tepat **sebelum** baris `refuse`:

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

### Menu dashboard (apa yang dikelola dari UI)

Dashboard `dnstrust-admin` di `https://<IP>:9080` mengelola hampir semua config.
Ini memetakan menu ke file di baliknya:

| Menu dashboard | Page header | File yang dikelola |
|---|---|---|
| **Client access** | *Recursive clients* | `/etc/unbound/unbound.conf` (baris `access-control`) |
| **Local DNS records** | *Local DNS records* | `/etc/unbound/hosts.conf` (maks 1000 record) |
| **Block page** | *IP halaman blokir* | `/etc/unbound/lamanlabuh.conf` (1–8 alamat) |
| **Whitelist** | *Whitelist* | `/etc/unbound/whitelist.conf` (maks 5000 domain) |
| **SafeSearch** | *SafeSearch* | `/etc/unbound/safesearch.conf` + `rpz.safesearch` |
| **DNS options** | *DNS options* | `/etc/unbound/module-config.conf`, TPROXY |
| **Setting** | *Settings* | `/etc/dnstrust-admin/config.json`, jadwal updater, password |

**Penting:** semua menu di atas **menulis ulang file-nya sendiri** saat kamu
simpan. Kalau kamu edit manual lalu simpan dari dashboard, perubahan manualmu
tertimpa. Backup otomatis ada di `/var/lib/dnstrust-admin/backups/`.

Untuk setup baru, lebih rapi lewat dashboard daripada edit file langsung.

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

1. **arm64 tidak didukung.** Binary hanya x86_64, tanpa source. Tidak ada jalan
   pintas — QEMU/binfmt ditolak untuk produksi (lambat, mmap CDB crash).

2. **RPZ dan local-zone tidak cukup.** 9,75 juta domain butuh ~11,7 GB dengan RPZ,
   ~5,2 GB dengan local-zone. Hanya CDB yang muat. Jangan coba jalur lain.

3. **Dua user terpisah: `dnstrust` dan `dnstrust-admin`.** Jangan disatukan,
   jangan `chown -R` ke salah satunya saja. Salah owner = dashboard crash dengan:

   ```
   buka database metrik: unable to open database file: out of memory (14)
   ```

   **`out of memory (14)` di sini BUKAN RAM habis** — itu `SQLITE_CANTOPEN`.
   Artinya proses `dnstrust-admin` tidak bisa membuka `metrics.db` karena
   ownership salah. Perbaikan:

   ```bash
   chown root:dnstrust-admin /var/lib/dnstrust-admin/metrics.db*
   chmod 640 /var/lib/dnstrust-admin/metrics.db*
   systemctl restart dnstrust-admin
   ```

   Ownership yang benar:

   | Path | Owner | Mode |
   |---|---|---|
   | `/var/lib/dnstrust` | `dnstrust:dnstrust` | 750 |
   | `/var/lib/dnstrust-admin` | `root:dnstrust-admin` | 770 |
   | `/var/lib/dnstrust-admin/metrics.db*` | `root:dnstrust-admin` | 640 |
   | `/var/lib/dnstrust-admin/{actions,queue,backups}` | `root:dnstrust-admin` | 770 |

4. **`dnstrust-control` tidak punya `reload`.** Perintah reload yang benar:

   ```bash
   /usr/local/sbin/unbound-control reload
   ```

   `dnstrust-control` hanya untuk `refresh`. Pakai yang salah = config tidak
   diterapkan, tanpa pesan error yang jelas.

5. **nginx butuh `restart`, bukan `reload`**, saat mengubah `default_server`.
   Reload tidak mengganti vhost default — browser tetap dapat `Welcome to nginx!`.

6. **Dashboard punya menu "Client access" untuk ACL.** Pakai itu untuk perubahan
   normal; edit manual `unbound.conf` hanya kalau dashboard mati. Kalau kamu
   edit manual lalu simpan dari dashboard, **perubahan manualmu bisa tertimpa** —
   dashboard menulis ulang seluruh blok `access-control` dari state internalnya.
   Backup dashboard ada di `/var/lib/dnstrust-admin/backups/`.

7. **Dashboard menulis ulang config saat kamu simpan.** Menu **Block page**,
   **Client access**, **Local DNS records**, **Whitelist** semuanya menulis file
   masing-masing. Setelah `install.sh` mengubah `lamanlabuh.conf`, kalau kamu
   buka **Block page** di dashboard dan simpan, nilai manual bisa tergantikan.

8. **`strings` belum tentu terinstall.** Saat memeriksa isi binary di Debian
   minimal, `strings` bisa tidak ada (`binutils` belum terpasang). Output
   `command not found` yang masuk ke `grep` akan **kosong**, dan kosong itu mudah
   salah dibaca sebagai "fitur tidak ada". Selalu:

   ```bash
   command -v strings >/dev/null || apt-get install -y binutils
   ```

9. **Klien harus diarahkan ke resolver.** Install di server tidak otomatis
   mengganti DNS pelanggan. Set lewat DHCP router/PPPoE pool.

10. **`resolv.conf` di LXC dikelola Proxmox.** Kalau di dalam CT terlihat penanda
    `# --- BEGIN PVE ---`, perubahan bisa hilang saat restart. Ubah permanen dari
    host: `pct set <vmid> --nameserver 127.0.0.1`.

11. **Dashboard :9080 terbuka publik dengan self-signed cert.** Taruh di belakang
    nginx + Let's Encrypt, atau batasi firewall ke IP admin. Tidak ada rate limit.

12. **Halaman blokir tidak andal untuk HTTPS.** Browser minta sertifikat domain
    yang diblokir, nginx memberi sertifikat lain, dan browser menampilkan
    "Not Secure" **sebelum** halaman muncul. Hanya HTTP yang andal.

13. **`0.0.0.0/0 allow` jangan permanen.** Server jadi open resolver, bahan DDoS
    amplification. Maksimum 100 jaringan di dashboard.

14. **Kredensial di chat/dokumen = bocor.** Ganti password root dan password
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
├── install.sh                     # installer utama — satu perintah
├── verify.sh                      # verifikasi end-to-end (16 pemeriksaan)
├── install-lamanlabuh.sh          # hanya halaman blokir (kalau DNS sudah ada)
├── src/
│   ├── bin/                       # binary x86_64 dari repo upstream (26 MB)
│   │   ├── unbound                # resolver dipatch filter-database (CDB)
│   │   ├── unbound-control
│   │   ├── unbound-checkconf
│   │   ├── dnstrust-admin         # dashboard :9080
│   │   ├── blcreate               # builder CDB
│   │   └── libcdb.so.1            # shared lib CDB
│   └── scripts/
│       ├── dnstrust-control       # wrapper unbound-control
│       ├── update-blacklist.sh    # updater Komdigi
│       └── verify-dnstrust-hot-remap
├── config/
│   ├── unbound/
│   │   ├── unbound.conf            # config utama + ACL
│   │   ├── forwarder.conf          # rekursif murni (isinya komentar)
│   │   ├── hosts.conf
│   │   ├── lamanlabuh.conf         # local-data blokir -> IP server
│   │   ├── module-config.conf      # respip validator iterator
│   │   ├── safesearch.conf         # RPZ safesearch
│   │   ├── tproxy.conf             # TPROXY (disabled default)
│   │   └── whitelist.conf          # 64 domain whitelist
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
│   └── index.html                  # halaman blokir KOMDIGI, CSS inline (207 KB)
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
