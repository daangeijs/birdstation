# birdmic: the Raspberry Pi side

Raspberry Pi 2 Model B v1.1 with a USB microphone, wired Ethernet over PoE,
read-only root. It runs ffmpeg and MediaMTX and serves
`rtsp://birdmic.example.lan:8554/mic` (L16, 48 kHz, mono).
The contract lives in [../docs/interface-contract.md](../docs/interface-contract.md).

```
pi/
  image/flash.sh        Raspberry Pi OS Lite (armhf) + cloud-init first boot
  ansible/site.yml      base, audio, mediamtx, readonly (in that order)
  ansible/inventory/    host and group_vars/birdmic.yml (every tunable)
```

Workstation needs: Raspberry Pi Imager (macOS; on Linux the script falls back
to `xz | dd` if Imager is missing), `curl`, `shasum` or `sha256sum`, `xz`,
`ansible-core` (for example `uv tool install ansible-core`, optionally
`ansible-lint`).

Replace `birdmic.example.lan` with the name or IP of your Pi in
`ansible/inventory/hosts.yml` (and `birdmic_fqdn` in
`ansible/inventory/group_vars/birdmic.yml`).

## Quick start

### 1. Flash (dry run first)

```sh
cd pi/image
./flash.sh                         # download + verify the image, render cloud-init
./flash.sh --device /dev/disk6     # also run every safety check on the card
```

The dry run prints `diskutil list`, the target's details, the cloud-init
files, and the exact Imager command it would run. Nothing is written.

### 2. Flash for real

```sh
./flash.sh --write --device /dev/disk6
```

You type the device path again; macOS then asks for your password
(Imager uses `authopen` for raw disk access). The script refuses the boot
disk, anything backing a mounted system volume, synthesized and disk-image
devices, and disks over 256 GB. Imager's own removable-drive check stays on.

First boot settings (flags on `flash.sh`): hostname `birdmic`, user `pi`
with `~/.ssh/id_ed25519.pub`, password login locked, SSH on, Ethernet DHCP,
timezone Europe/Amsterdam, locale en_GB.UTF-8. They are written as
cloud-init `user-data`/`network-config` on the boot partition, which is how
current (Trixie based) Raspberry Pi OS images do headless setup.

### 3. Network

1. Boot the Pi, find its MAC address in your router and add a DHCP reservation.
2. Add a local DNS record for it (for example `birdmic.example.lan`) in your
   router or DNS server. mDNS (`birdmic.local`) is switched off by the base
   role, so use DNS or the IP address.
3. `ssh pi@birdmic.example.lan` should work without a password.

If you use another user name (`flash.sh --user`), change `remote_user` in
`ansible/ansible.cfg` and `ansible_user` in `ansible/inventory/hosts.yml`.

### 4. Provision

Plug in the microphone first (the audio role probes it).

```sh
cd pi/ansible
ansible-playbook site.yml
```

This upgrades the OS, quiets it down, detects the USB card, sets the capture
gain, installs MediaMTX, checks the stream is up, then enables the overlay
root and reboots. Look for `[WARNING]` lines from the probe: they tell you the
card's native rate when ffmpeg has to resample to 48 kHz.

### 5. Verify

```sh
ffprobe -rtsp_transport tcp rtsp://birdmic.example.lan:8554/mic
# expect: Audio: pcm_s16be, 48000 Hz, mono

curl -s http://birdmic.example.lan:9997/v3/paths/get/mic | jq '{available, inboundBytes}'
ssh pi@birdmic.example.lan findmnt /    # FSTYPE overlay
```

### 6. Power-cut test

Pull the PoE cable while streaming, plug it back in, and repeat step 5 after
about a minute. Nothing should need a fsck, and the stream returns on its
own (systemd starts MediaMTX, MediaMTX restarts ffmpeg).

## Maintenance

### Make it writable

Running `site.yml` on a locked Pi changes nothing: it reports that the root
is an overlay and stops. To change something:

```sh
ansible-playbook site.yml -e birdmic_readonly=false   # unlock, reboot, apply, stay writable
# ...edit group_vars or poke around...
ansible-playbook site.yml                             # apply and lock again
```

By hand on the Pi:

```sh
sudo raspi-config nonint disable_overlayfs && sudo reboot
sudo raspi-config nonint disable_bootro     # if /boot/firmware is read-only too
# ...changes...
sudo raspi-config nonint enable_bootro && sudo raspi-config nonint enable_overlayfs && sudo reboot
```

The roles refuse to run against an overlay root (the `guard` role), because
the changes would vanish at the next reboot.

### Swap the microphone

The card is picked by its ALSA name, so a new microphone needs no code
change: plug it in and run the unlock / lock cycle above. With
`birdmic_alsa_card: ""` the first USB capture card is used. To pin one, set
it to the id from `cat /proc/asound/card*/id` (for example `Headset` or the
Sound Blaster Play! 3's id). The rate is probed again; 48 kHz cards skip
resampling.

### Push to a relay (phase 2)

```yaml
birdmic_mode: push
birdmic_push_url: rtsp://relay.example.lan:8554/birdmic
```

ffmpeg then runs as `birdmic-push.service` (`Restart=always`) and publishes
straight to the relay; MediaMTX on the Pi is stopped, so the Pi's API and
metrics go away and status comes from the relay. Switching back is
`birdmic_mode: serve`.

### Hardening

Auth, IP lists and RTSPS are variables in `group_vars/birdmic.yml`:
`birdmic_auth_enabled: true` switches from `birdmic_auth_open_users` to
`birdmic_auth_users` (passwords from a vault), and `birdmic_rtsp_encryption`
(`no`, `optional`, `strict`) uses `birdmic_rtsp_server_key`/`_cert`.

## Future options

- **Alpine Linux diskless** (`lbu`): runs from RAM by design, so power cuts
  are a non-event and there is no overlay to manage. Needs its own
  provisioning (apk, OpenRC) and a commit step for config changes.
- **Buildroot**: a tiny purpose-built image with only ffmpeg and MediaMTX.
  Fastest boot and smallest attack surface, but every change is an image
  rebuild.
