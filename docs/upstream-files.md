# File yang harus diambil dari repo upstream

Repo ini berisi **konfigurasi** instalasi yang sudah terbukti jalan.
Binary tidak disertakan karena besar (~50 MB) dan berlisensi upstream.

Ambil dari [niammuddin/zet-dns](https://github.com/niammuddin/zet-dns).

## Cara cepat

Repo asli punya `install.sh` yang mengunduh dan memasang semuanya otomatis:

```bash
git clone https://github.com/niammuddin/zet-dns /root/zet-dns
cd /root/zet-dns
printf '%s\n' 'PASSWORD_DASHBOARD' | script -qec "./install.sh" /tmp/zetdns-install.log
```

`script -qec` diperlukan karena installer meminta password lewat `stty -echo`.

## Daftar file yang dipasang installer

Kalau kamu perlu memasang manual, ini file yang penting:

| Tujuan di server | Asal di repo upstream | Ukuran | Fungsi |
|---|---|---|---|
| `/usr/local/sbin/unbound` | `src/bin/unbound` | 5,3 MB | resolver + patch `filter-database:` |
| `/usr/local/sbin/unbound-checkconf` | `src/bin/unbound-checkconf` | 4,5 MB | validasi config |
| `/usr/local/sbin/unbound-control` | `src/bin/unbound-control` | 4,5 MB | kontrol runtime (reload, stats) |
| `/usr/local/sbin/dnstrust-admin` | `src/bin/dnstrust-admin` | 12,7 MB | dashboard web :9080 |
| `/usr/local/sbin/dnstrust-control` | `src/scripts/dnstrust-control` | 97 B | wrapper kecil |
| `/usr/local/sbin/update-dnstrust-blacklist` | `src/scripts/update-blacklist.sh` | 15 KB | sinkronisasi Komdigi |
| `/usr/local/sbin/verify-dnstrust-hot-remap` | `src/scripts/verify-*.sh` | 3,8 KB | cek hot-remap |
| `src/bin/blcreate` | `src/bin/blcreate` | — | builder CDB (dipakai updater) |
| `src/bin/libcdb.so.1` | `src/bin/libcdb.so.1` | — | shared lib CDB |

## Yang ada di repo ini

| File | Asal |
|---|---|
| `bin/dnstrust-control` | `/usr/local/sbin/dnstrust-control` dari instalasi nyata |
| `config/**` | `/etc/unbound/*`, `/etc/systemd/system/*`, `/etc/default/*` |
| `lamanlabuh/index.html` | `/var/www/lamanlabuh/index.html` |
| `config/nginx/lamanlabuh.conf` | `/etc/nginx/sites-available/lamanlabuh` |

## Arsitektur yang didukung

**Hanya x86_64.** `install-dns.sh` baris 62-68 keluar dengan:

```
unsupported architecture: aarch64; this release contains Linux amd64 binaries
```

Tidak ada source dirilis. Untuk arm64, kamu harus:

1. Build Unbound 1.25.x dari source
2. Mempatch `filter-database:` (dependensi `libcdb`)
3. Build `dnstrust-admin` dari source — **tidak tersedia**

Poin 3 yang jadi penghalang: `dnstrust-admin` hanya binary. Tanpa dashboard,
kamu masih bisa pakai Unbound + updater manual, tapi harus edit config langsung.

**Jangan** coba jalankan binary x86_64 di arm64 lewat `qemu-user`/`binfmt` untuk
produksi: lambat, dan mmap CDB berisiko crash.

## Verifikasi binary

Setelah instalasi, cek versi:

```bash
/usr/local/sbin/unbound -V | head -2
```

Harus mengandung:

```
Version 1.25.1
Configure line: --prefix=/usr/local --sysconfdir=/etc \
                --with-conf-file=/etc/unbound/unbound.conf \
                --with-libevent --with-libexpat=/usr --disable-flto
```

Kalau versi yang muncul `1.17.1` (versi apt), berarti binary patched tidak
terpasang — `filter-database:` tidak akan dikenal dan CDB tidak akan dibaca.

Cek patch tersedia:

```bash
strings /usr/local/sbin/unbound | grep -i filter-database
```

Harus keluar. Kalau kosong, kamu pakai Unbound upstream tanpa patch.
