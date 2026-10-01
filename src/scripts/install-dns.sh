#!/bin/sh
set -eu

test "$(id -u)" -eq 0 || {
    echo "install.sh must run as root" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUNDLE_DIR=${1:-"$SCRIPT_DIR"}
ARTIFACT_ROOT=$BUNDLE_DIR/src

artifact_path() {
    name=$1
    for dir in bin scripts systemd etc/unbound etc; do
        if [ -f "$ARTIFACT_ROOT/$dir/$name" ]; then
            printf '%s/%s/%s\n' "$ARTIFACT_ROOT" "$dir" "$name"
            return 0
        fi
    done
    return 1
}

for required in \
    unbound \
    unbound-checkconf \
    unbound-control \
    dnstrust-unbound \
    verify-dnstrust-hot-remap \
    dnstrust-control \
    blcreate \
    libcdb.so.1 \
    update-blacklist.sh \
    unbound.conf \
    module-config.conf \
    lamanlabuh.conf \
    forwarder.conf \
    hosts.conf \
    tproxy.conf \
    rpz.safesearch \
    safesearch.conf \
    whitelist.conf \
    dnstrust-unbound.service \
    unbound-blacklist-update.service \
    unbound-blacklist-update.timer \
    unbound-blacklist-update.env \
    nftables.conf \
    disable-stub.conf; do
    test -s "$(artifact_path "$required")" || {
        echo "missing bundle artifact: $required" >&2
        exit 1
    }
done

for command in ldconfig runuser unbound-anchor sshd nft systemctl dig; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "required host command missing: $command" >&2
        exit 1
    }
done

case "$(uname -m)" in
    x86_64|amd64) ;;
    *)
        echo "unsupported architecture: $(uname -m); this release contains Linux amd64 binaries" >&2
        exit 1
        ;;
esac

test -d /run/systemd/system || {
    echo "systemd is not running as PID 1; boot the host normally before installing ZetDNS" >&2
    exit 1
}

nft list tables >/dev/null 2>&1 || {
    echo "nftables is not usable; containers need NET_ADMIN, while VM/bare metal need a working nftables kernel" >&2
    exit 1
}

VIRTUALIZATION=bare-metal
if command -v systemd-detect-virt >/dev/null 2>&1; then
    detected=$(systemd-detect-virt 2>/dev/null || true)
    test -z "$detected" || test "$detected" = none || VIRTUALIZATION=$detected
fi
echo "Platform detected: $VIRTUALIZATION"
case "$VIRTUALIZATION" in
    kvm|qemu)
        systemctl list-unit-files qemu-guest-agent.service >/dev/null 2>&1 || \
            echo "Optional: install qemu-guest-agent for KVM/Proxmox host integration."
        ;;
    vmware)
        systemctl list-unit-files open-vm-tools.service >/dev/null 2>&1 || \
            echo "Optional: install open-vm-tools for VMware host integration."
        ;;
esac

# Preserve both the current Whitelist and the retired Local overrides file.
# Older dashboard versions wrote identical `local-zone ... whitelist` records
# to two files. The new layout keeps them in whitelist.conf only.
LEGACY_ALLOWLIST=$(mktemp)
cleanup() { rm -f "$LEGACY_ALLOWLIST"; }
trap cleanup EXIT INT TERM
if test -e /etc/unbound/local.conf; then
    POLICY_BACKUP=/var/backups/zetdns-policy-migration-$(date -u +%Y%m%dT%H%M%SZ)
    install -d -m 0700 "$POLICY_BACKUP"
    cp -a /etc/unbound/local.conf "$POLICY_BACKUP/local.conf"
    if test -e /etc/unbound/whitelist.conf; then
        cp -a /etc/unbound/whitelist.conf "$POLICY_BACKUP/whitelist.conf"
    fi
    echo "Legacy policy backup: $POLICY_BACKUP"
fi
for source in /etc/unbound/whitelist.conf /etc/unbound/local.conf; do
    if test -s "$source"; then
        sed -n \
            -e 's/^[[:space:]]*local-zone:[[:space:]]*"\([^"]*\)"[[:space:]]*whitelist[[:space:]]*$/\1/p' \
            -e "s/^[[:space:]]*local-zone:[[:space:]]*'\\([^']*\\)'[[:space:]]*whitelist[[:space:]]*$/\\1/p" \
            "$source" >> "$LEGACY_ALLOWLIST"
    fi
done

id dnstrust >/dev/null 2>&1 || \
    useradd --system --home-dir /var/lib/dnstrust --shell /usr/sbin/nologin dnstrust

install -d -o root -g root -m 0755 /etc/unbound /etc/systemd/system
install -d -o dnstrust -g dnstrust -m 0750 /etc/unbound/run /var/lib/dnstrust
install -d -o dnstrust -g dnstrust -m 0750 /run/dnstrust
install -d -o root -g root -m 0755 /usr/local/libexec

install -o root -g root -m 0755 "$(artifact_path unbound)" /usr/local/sbin/unbound
install -o root -g root -m 0755 "$(artifact_path unbound-checkconf)" /usr/local/sbin/unbound-checkconf
install -o root -g root -m 0755 "$(artifact_path unbound-control)" /usr/local/sbin/unbound-control
install -o root -g root -m 0755 "$(artifact_path dnstrust-unbound)" /usr/local/libexec/dnstrust-unbound
install -o root -g root -m 0755 "$(artifact_path verify-dnstrust-hot-remap)" /usr/local/sbin/verify-dnstrust-hot-remap
install -o root -g root -m 0755 "$(artifact_path blcreate)" /usr/local/bin/blcreate
install -o root -g root -m 0755 "$(artifact_path update-blacklist.sh)" /usr/local/sbin/update-dnstrust-blacklist
install -o root -g root -m 0755 "$(artifact_path dnstrust-control)" /usr/local/sbin/dnstrust-control
install -o root -g root -m 0644 "$(artifact_path libcdb.so.1)" /usr/local/lib/libcdb.so.1

install -o root -g root -m 0644 "$(artifact_path unbound.conf)" /etc/unbound/unbound.conf
install -o root -g root -m 0644 "$(artifact_path module-config.conf)" /etc/unbound/module-config.conf
install -o root -g root -m 0644 "$(artifact_path lamanlabuh.conf)" /etc/unbound/lamanlabuh.conf
install -o root -g root -m 0644 "$(artifact_path whitelist.conf)" /etc/unbound/whitelist.conf
while IFS= read -r domain; do
    test -n "$domain" || continue
    line="local-zone: \"$domain\" whitelist"
    grep -Fqx "$line" /etc/unbound/whitelist.conf || printf '%s\n' "$line" >> /etc/unbound/whitelist.conf
done < "$LEGACY_ALLOWLIST"
install -o root -g root -m 0644 "$(artifact_path forwarder.conf)" /etc/unbound/forwarder.conf
install -o root -g root -m 0644 "$(artifact_path hosts.conf)" /etc/unbound/hosts.conf
install -o root -g root -m 0644 "$(artifact_path tproxy.conf)" /etc/unbound/tproxy.conf
install -o root -g root -m 0644 "$(artifact_path rpz.safesearch)" /etc/unbound/rpz.safesearch
install -o root -g root -m 0644 "$(artifact_path safesearch.conf)" /etc/unbound/safesearch.conf
install -o root -g root -m 0644 "$(artifact_path dnstrust-unbound.service)" /etc/systemd/system/dnstrust-unbound.service
install -o root -g root -m 0644 "$(artifact_path unbound-blacklist-update.service)" /etc/systemd/system/unbound-blacklist-update.service
install -o root -g root -m 0644 "$(artifact_path unbound-blacklist-update.timer)" /etc/systemd/system/unbound-blacklist-update.timer
install -o root -g root -m 0644 "$(artifact_path unbound-blacklist-update.env)" /etc/default/unbound-blacklist-update
NFTABLES_CONFIG_CREATED=no
if test ! -e /etc/nftables.conf; then
    install -o root -g root -m 0644 "$(artifact_path nftables.conf)" /etc/nftables.conf
    NFTABLES_CONFIG_CREATED=yes
else
    echo "Keeping existing host firewall: /etc/nftables.conf"
fi
install -d -o root -g root -m 0755 /etc/systemd/resolved.conf.d
install -o root -g root -m 0644 "$(artifact_path disable-stub.conf)" /etc/systemd/resolved.conf.d/disable-stub.conf

ldconfig

if test ! -s /var/lib/dnstrust/root.key; then
    if ! runuser -u dnstrust -- \
        /usr/sbin/unbound-anchor -a /var/lib/dnstrust/root.key; then
        test -s /var/lib/dnstrust/root.key || {
            echo "unable to initialize DNSSEC root trust anchor" >&2
            exit 1
        }
    fi
fi

if test ! -s /var/lib/dnstrust/blacklist.db; then
    printf '%s\n' seed.invalid > /var/lib/dnstrust/trust.txt
    (
        cd /var/lib/dnstrust
        /usr/local/bin/blcreate < trust.txt
    )
    chown dnstrust:dnstrust /var/lib/dnstrust/trust.txt /var/lib/dnstrust/blacklist.db
    chmod 0644 /var/lib/dnstrust/blacklist.db
fi

/usr/local/sbin/unbound-checkconf /etc/unbound/unbound.conf
rm -f /etc/unbound/local.conf
/usr/sbin/sshd -t
/usr/sbin/nft -c -f /etc/nftables.conf

systemctl daemon-reload
if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    systemctl restart systemd-resolved.service
else
    echo "systemd-resolved.service not found; skipping restart"
fi
systemctl enable --now dnstrust-unbound.service
systemctl enable --now unbound-blacklist-update.timer
if systemctl is-active --quiet nftables.service; then
    echo "Existing nftables service remains active; its configuration was not replaced."
elif test "$NFTABLES_CONFIG_CREATED" = yes; then
    echo "ZetDNS nftables template installed but not activated; host firewall state remains unchanged."
else
    echo "Existing /etc/nftables.conf is inactive and was left unchanged."
fi
systemctl reload ssh.service

echo "Fresh DNS Trust baseline installed"
