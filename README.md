# macbook-server

Runbook: 2019 MacBook Pro 16" (A2141, `MacBookPro16,1`, i9, T2) → headless Ubuntu 26.04 server.
Lid closed, in a wardrobe, wired to Router A, SSH only.

Verified against the [t2linux wiki](https://wiki.t2linux.org) and
[T2-Ubuntu v7.1.8-1](https://github.com/t2linux/T2-Ubuntu/releases) (2026-09-03) on 2026-09-17.

## Network plan

```
Internet ── Router A (Huawei EG8145V5, 192.168.100.1)
              ├── MacBook   192.168.100.100  (static, USB-C Ethernet)
              └── Router B (Xiaomi AX3200, 192.168.31.1, NAT) ── Wi-Fi: phone, laptop, PC, printer
```

- Wi-Fi clients → MacBook: works (checked: PC → 192.168.31.1 → 192.168.100.1, 2 hops).
- MacBook → anything behind Router B: **does not work** (NAT). Replies to SSH sessions are fine.
  Need it later? Port-forward on B, or Tailscale.
- mDNS (`macbook.local`) does not cross Router B. Use the IP.

Ethernet adapter on hand: RTL8152, **100 Mbit**, driver `r8152` (mainline). Fine for install.
Replace with an RTL8153 (1G) / RTL8156 (2.5G) adapter later — same driver, netplan below matches
any adapter, no reconfiguration.

## 0. Prepare macOS

Order matters: erase first, security settings last (they need the *new* admin account).

1. **Update** to the latest macOS (Tahoe 26.x — the last release for Intel). This also updates
   T2 firmware. After it finishes, check Software Update once more until it offers nothing.
2. **Battery health** — System Settings → Battery → Battery Health, and  → System Information →
   Power (cycle count, condition). "Service Recommended" or a bulging case: **stop, replace the
   battery first.** It will sit at 100% in a closed wardrobe; Linux on T2 has no charge limiter.
3. **Wipe:** System Settings → General → Transfer or Reset → **Erase All Content and Settings**.
   Enter the Apple ID password when asked — that turns off Find My / Activation Lock, which
   must not stay on. Takes minutes, keeps the updated OS; no need to reinstall from Recovery.
4. **Setup Assistant, minimal.** The Mac must reach Apple once to re-activate: plug in the
   Ethernet hub, or join Wi-Fi this one time. Then decline everything:
   - Migration: Not Now · Apple ID: Set Up Later → Skip · Location, Analytics, Siri, Screen Time,
     Touch ID: off/skip · **FileVault: off**
   - Create one local admin account. **Remember its password** — step 6 asks for it.
   - A "Remote Management" screen here means the Mac is enrolled in a company MDM. Stop; that
     must be released by the organisation first.
5. **Partition:** Disk Utility → View → Show All Devices → select the top-level *APPLE SSD* →
   Partition → **+ → Add Partition** (not Volume): name `Linux`, format exFAT, size = everything
   except ~60 GB for macOS (fresh Tahoe is ~25 GB; the rest is room for security updates).
   Can't be resized later. Keep macOS: only source of T2 firmware updates, and the recovery path.
   If it refuses to shrink: `tmutil deletelocalsnapshots /` in Terminal, retry.
6. **Disable Secure Boot:** shut down. Power on holding `Cmd-R` → Recovery → Utilities →
   **Startup Security Utility** (asks for the admin password from step 4):
   - Secure Boot: **No Security**
   - Allow Boot Media: **Allow booting from external or removable media**
   - Firmware password: must be **off**
7. Shut down. macOS is done; it should never need to boot again except for firmware updates.

## 1. Router A

Admin UI (`192.168.100.1` → LAN → DHCP Server): `192.168.100.100` must be **outside** the DHCP
pool. Done 2026-09-17: pool set to `.101`–`.254` (Huawei's default covers the whole /24).
Static addresses go in `.2`–`.100`.

## 2. Build the installer USB (on the Linux PC)

```bash
cd ~/Downloads
curl -LO https://github.com/t2linux/T2-Ubuntu/releases/latest/download/iso.sh
bash iso.sh            # pick 1 (Ubuntu), 2 (26.04). Joins the 4 parts into ~/Downloads, verifies sha256

lsblk -o NAME,SIZE,MODEL,TRAN      # find the USB stick. Triple-check the device name.
sudo dd if=ubuntu-26.04-*-t2-resolute.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

There is no T2 server ISO; we install the desktop image and turn the GUI off (step 5).
A stock Ubuntu Server ISO lacks the T2 kernel (no internal keyboard, NVRAM writes can panic
without `efi=noruntime`) — not worth it.

## 3. Install

1. Plug in the USB stick and the Ethernet hub (any router, DHCP is fine for the install).
2. Power on holding `Option (⌥)` → pick the orange **EFI Boot** → Enter.
3. Installer → **Manual installation** (never automatic — it erases macOS):
   - delete the exFAT `Linux` partition, create `ext4` mounted at `/` in its place
   - `/dev/nvme0n1p1` → mount at `/boot/efi`, **do not format**
   - touch nothing else (the APFS partition is macOS)
4. Hostname `macbook`, create your user. Finish, remove the USB stick, reboot.
5. Hold `Option (⌥)` → **hold `Control`** and select **EFI Boot** → Enter.
   Control makes it the default, so it boots Linux unattended from now on.
   (Booting/upgrading macOS later resets this default — redo this step afterwards.)

Blank screen after GRUB? See the wiki's rEFInd guide. Otherwise ignore rEFInd.

## 4–6, automated

Steps 4, 5 and the checks of step 6 are in [`setup.sh`](setup.sh). On the freshly installed
MacBook (console, or SSH to its DHCP address):

```bash
wget -qO- https://raw.githubusercontent.com/iztiev/macbook-server/main/setup.sh | sudo bash
# move the cable to Router A, then
sudo reboot
# from the PC, after it's back:
ssh USER@192.168.100.100
wget -qO- https://raw.githubusercontent.com/iztiev/macbook-server/main/setup.sh | bash -s verify
```

SSH keys come from <https://github.com/iztiev.keys> (add a client's key on GitHub *before*
running, or append it to `~/.ssh/authorized_keys` later). Password login is disabled only if at
least one key got installed. Re-running is safe. The physical tests in step 6 stay manual.

The manual equivalent follows, for reference and troubleshooting.

## 4. Base config (at the MacBook, screen still open)

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y openssh-server lm-sensors

# t2 kernel repo — check it's there so kernel updates keep coming
grep -r t2-ubuntu-repo /etc/apt/sources.list.d/ || echo "MISSING: add it, see below"
```

If missing: follow <https://github.com/AdityaGarg8/t2-ubuntu-repo#apt-repository-for-t2-macs>
(common repo + the `resolute` release repo), then `sudo apt install linux-t2`.

### Static IP (systemd-networkd, any adapter)

NetworkManager can't do netplan name globs, and a desktop network stack has no business on a
server — switch the renderer.

```bash
sudo mkdir -p /root/netplan-orig && sudo mv /etc/netplan/*.yaml /root/netplan-orig/
sudo tee /etc/netplan/01-wired.yaml >/dev/null <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    wired:
      match: { name: "en*" }     # no built-in NIC, so this is whatever USB adapter is plugged in
      addresses: [192.168.100.100/24]
      routes: [{ to: default, via: 192.168.100.1 }]
      nameservers: { addresses: [192.168.100.1, 1.1.1.1] }
EOF
sudo chmod 600 /etc/netplan/01-wired.yaml
sudo systemctl disable --now NetworkManager NetworkManager-wait-online
sudo systemctl mask NetworkManager
sudo netplan apply
```

Move the cable to **Router A** now, then: `ip -br addr && ping -c3 192.168.100.1 && ping -c3 ubuntu.com`

### SSH, keys only

On the Linux PC:

```bash
ssh-copy-id USER@192.168.100.100
cat >> ~/.ssh/config <<'EOF'
Host macbook
    HostName 192.168.100.100
    User USER
EOF
ssh macbook true && echo OK
```

Only after that prints `OK`, on the MacBook:

```bash
echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/10-keys-only.conf
sudo systemctl restart ssh
```

Repeat `ssh-copy-id` from the other clients *before* this, or append their public keys to
`~/.ssh/authorized_keys` afterwards.

## 5. Headless config (over SSH from here on)

```bash
# no GUI. Desktop packages stay on disk, unused. Purging them is churn for ~2 GB.
sudo systemctl set-default multi-user.target

# lid closed = do nothing
sudo mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
  | sudo tee /etc/systemd/logind.conf.d/lid.conf

# suspend is unreliable on T2 and fatal for a box you can't reach. Make it impossible.
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# panel off after 60 s. APPENDS to the existing t2 kernel params — do not replace them.
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=60"/' /etc/default/grub
sudo update-grub

# AMD GPU: keep amdgpu loaded (an undriven dGPU runs hotter) but pin it to lowest power state
echo 'SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="low"' \
  | sudo tee /etc/udev/rules.d/30-amdgpu-pm.rules

# radios off for good. The ISO may have pulled Wi-Fi firmware from macOS on its own.
printf 'blacklist brcmfmac\nblacklist hci_bcm4377\n' | sudo tee /etc/modprobe.d/no-wireless.conf

sudo reboot
```

## 6. Verify (after reboot, lid open)

```bash
systemctl get-default                                        # multi-user.target
ip -br addr | grep 192.168.100.100                           # static IP up
cat /sys/bus/pci/drivers/amdgpu/*/power_dpm_force_performance_level   # low
lsmod | grep -cE 'brcmfmac|hci_bcm4377'                      # 0
ip link show | grep -c wl                                    # 0
cat /sys/class/power_supply/BAT0/{status,capacity,cycle_count}
sensors | grep -Ei 'package|fan|edge'
```

Then the tests that matter, **before** it goes in the wardrobe:

1. **Lid:** close it, wait 2 min, `ssh macbook uptime` from the PC. Must answer.
2. **Reboot with lid closed:** `ssh macbook sudo reboot`. Must come back on its own within ~2 min.
   If not: default boot entry isn't set (step 3.5).
3. **Heat:** lid closed, `stress-ng --cpu 16 --timeout 10m` (apt install stress-ng) while watching
   `watch -n2 sensors`. Fans should ramp; package temp should plateau below ~95 °C.
   Repeat once it's in the wardrobe, door shut. This is the test that decides if the wardrobe works.
4. **Power loss:** pull the charger. It keeps running on battery (free UPS). Whether it powers
   itself back on after the battery drains fully, lid closed, is **unknown** — assume not, and
   expect to open the wardrobe after a multi-hour outage.

## Knobs, if the tests say so

| Symptom | Knob |
|---|---|
| Too hot under load | Disable turbo: `echo 'w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 1' \| sudo tee /etc/tmpfiles.d/no-turbo.conf` + reboot. Big temperature drop, modest speed loss. |
| Fans too lazy | `sudo apt install t2fanrd && sudo systemctl enable --now t2fanrd`, curve in `/etc/t2fand.conf`. Default T2-managed fans are usually fine. |
| Freezes + fans screaming | dGPU. Wiki: `echo 'options apple-gmux force_igd=y' \| sudo tee /etc/modprobe.d/apple-gmux.conf`, or kernel param `amdgpu.dpm=0`. |
| USB-C adapter flaky | kernel param `pcie_ports=native` (wiki). |

## Operations

- **Updates:** `sudo apt update && sudo apt full-upgrade`. Kernel comes from the t2 repo.
  GRUB keeps the previous kernel; a bad kernel means opening the wardrobe and picking it
  from GRUB → Advanced. Don't reboot into a new kernel right before leaving on holiday.
- **Battery, monthly:** `ssh macbook cat /sys/class/power_supply/BAT0/cycle_count` and *look at
  the machine* — a lid that no longer closes flat or a wobbling case means a swelling battery.
  Unplug and replace. Do not run it without a battery: Intel MacBooks throttle to ~1 GHz.
- **Swapping the Ethernet adapter:** shut down, swap, boot. Nothing to edit.
- **Ubuntu release upgrade:** re-add the release-specific t2 repo for the new codename.

## Deliberately skipped

- Wi-Fi/Bluetooth firmware, audio, Touch Bar, suspend fixes, GPU switching — not needed headless.
- Purging desktop packages — disabled is enough.
- Tailscale — add when access from outside the LAN, or MacBook → Router-B devices, is needed.
- rEFInd — add only if GRUB shows a blank screen.
