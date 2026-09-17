#!/usr/bin/env bash
# Turns a fresh T2-Ubuntu desktop install into the headless server described in README.md.
#
#   wget -qO- https://raw.githubusercontent.com/iztiev/macbook-server/main/setup.sh | sudo bash
#   wget -qO- https://raw.githubusercontent.com/iztiev/macbook-server/main/setup.sh | bash -s verify   # after reboot
#
# Safe to re-run. Nothing network-related takes effect until the reboot at the end,
# so it can be run at the console or over SSH on the DHCP address.
set -euo pipefail

IP=192.168.100.100/24
GATEWAY=192.168.100.1
DNS="192.168.100.1, 1.1.1.1"
GH_USER=iztiev            # SSH public keys are taken from https://github.com/$GH_USER.keys

verify() {
    local fail=0
    check() { if eval "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
    check "boots to multi-user (no GUI)"  '[ "$(systemctl get-default)" = multi-user.target ]'
    check "static IP ${IP%/*} is up"      'ip -br addr | grep -qF "${IP%/*}/"'
    check "default route via $GATEWAY"    'ip route | grep -q "^default via $GATEWAY "'
    check "DNS + internet"                'getent hosts ubuntu.com'
    check "NetworkManager off"            '! systemctl is-active NetworkManager'
    check "sshd: passwords disabled"      'grep -rqs "^PasswordAuthentication no" /etc/ssh/sshd_config.d/'
    check "authorized_keys present"       '[ -s ~/.ssh/authorized_keys ] || [ -s "/home/${SUDO_USER:-}/.ssh/authorized_keys" ]'
    check "lid switch ignored"            'grep -qs "^HandleLidSwitch=ignore" /etc/systemd/logind.conf.d/lid.conf'
    check "suspend masked"                '[ "$(systemctl is-enabled suspend.target)" = masked ]'
    check "consoleblank on cmdline"       'grep -q consoleblank= /proc/cmdline'
    check "amdgpu pinned to low"          'grep -qx low /sys/bus/pci/drivers/amdgpu/*/power_dpm_force_performance_level'
    check "wireless drivers not loaded"   '! lsmod | grep -qE "^(brcmfmac|hci_bcm4377) "'
    check "turbo boost off"               'grep -qx 1 /sys/devices/system/cpu/intel_pstate/no_turbo'
    check "swap active"                  '[ -n "$(swapon --show --noheadings)" ]'
    check "t2 kernel running"            'uname -r | grep -q t2'
    check "t2 apt repo configured"        'grep -rqs t2-ubuntu-repo /etc/apt/sources.list.d/'
    echo
    local b=/sys/class/power_supply/BAT0
    # health baseline 2026-09-17: 81% at 1136 cycles. Replace below ~75%, on a fast drop, or any swelling.
    [ -d $b ] && echo "battery: $(cat $b/status) $(cat $b/capacity)%, $(cat $b/cycle_count) cycles," \
        "health $(( $(cat $b/charge_full) * 100 / $(cat $b/charge_full_design) ))% of design" || true
    sensors 2>/dev/null | grep -Ei 'package|fan' || true
    return $fail
}

if [ "${1:-}" = verify ]; then verify; exit; fi

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
TARGET_USER=${SUDO_USER:?run via sudo from your own account, not as root directly}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

echo "== packages"
dpkg --configure -a    # no-op normally; repairs an interrupted apt run
apt-get -o DPkg::Lock::Timeout=300 update
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 full-upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y openssh-server lm-sensors
grep -rqs t2-ubuntu-repo /etc/apt/sources.list.d/ \
    || echo "WARNING: t2 apt repo missing, kernel updates won't arrive. See README step 4." >&2

echo "== ssh keys from github.com/$GH_USER"
keys=$(wget -qO- "https://github.com/$GH_USER.keys" || true)
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.ssh"
auth="$TARGET_HOME/.ssh/authorized_keys"
touch "$auth"
while read -r key; do
    if [ -n "$key" ] && ! grep -qxF "$key" "$auth"; then echo "$key" >> "$auth"; fi
done <<< "$keys"
chown "$TARGET_USER:$TARGET_USER" "$auth" && chmod 600 "$auth"
# Never lock the door without a key inside.
[ -s "$auth" ] || { echo "no SSH keys installed, refusing to continue" >&2; exit 1; }
echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/10-keys-only.conf
systemctl enable ssh

echo "== static IP via systemd-networkd (applies on reboot)"
mkdir -p /root/netplan-orig
find /etc/netplan -maxdepth 1 -name '*.yaml' ! -name 01-wired.yaml -exec mv -t /root/netplan-orig/ {} +
cat > /etc/netplan/01-wired.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    wired:
      match: { name: "en*" }     # no built-in NIC, so this is whatever USB adapter is plugged in
      addresses: [$IP]
      routes: [{ to: default, via: $GATEWAY }]
      nameservers: { addresses: [$DNS] }
EOF
chmod 600 /etc/netplan/01-wired.yaml
netplan generate    # syntax check, fails the script before we reboot into a broken network
systemctl disable NetworkManager NetworkManager-wait-online 2>/dev/null || true
systemctl mask NetworkManager

echo "== swap"
# A little swap so memory pressure degrades instead of OOM-killing. File, not partition: resizable.
# ponytail: assumes ext4 root (fallocate swapfiles don't work on btrfs)
if [ -z "$(swapon --show --noheadings)" ]; then
    fallocate -l 4G /swap.img && chmod 600 /swap.img && mkswap /swap.img
    grep -q '^/swap.img' /etc/fstab || echo '/swap.img none swap sw 0 0' >> /etc/fstab
    swapon /swap.img
fi

echo "== headless"
systemctl set-default multi-user.target
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
    > /etc/systemd/logind.conf.d/lid.conf
# suspend is unreliable on T2 and fatal for a box nobody can reach
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# panel off after 60 s. Appends: the t2 kernel params already in there must stay.
grep -q consoleblank= /etc/default/grub \
    || sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=60"/' /etc/default/grub
update-grub

# keep amdgpu loaded (an undriven dGPU runs hotter) but pin it to its lowest power state
echo 'SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="low"' \
    > /etc/udev/rules.d/30-amdgpu-pm.rules

printf 'blacklist brcmfmac\nblacklist hci_bcm4377\n' > /etc/modprobe.d/no-wireless.conf

# Turbo off. Measured 2026-09-17, lid closed, stress-ng --cpu 16: turbo on = pinned at 100 °C,
# constant package throttling; turbo off = 60 °C. Costs burst speed, buys thermal headroom in a wardrobe.
# Knob: delete this file + reboot to get turbo back (or cap sustained power via RAPL instead).
echo 'w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 1' > /etc/tmpfiles.d/no-turbo.conf
echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo

cat <<EOF

Done. Plug the Ethernet cable into Router A, then:  sudo reboot
It comes back as ${IP%/*} with no GUI. From the PC:  ssh $TARGET_USER@${IP%/*}
Then check:  wget -qO- https://raw.githubusercontent.com/$GH_USER/macbook-server/main/setup.sh | bash -s verify
EOF
