# BirdStation

A bird listening station made from old hardware. A Raspberry Pi 2 from 2015
sits in a weatherproof box in the garden and streams uncompressed audio from
an old USB headset microphone over RTSP. BirdNET-Go, running on a small k3s
cluster at home, pulls the stream, identifies the birds and sends the
detections to Home Assistant over MQTT. The Pi runs from a read-only root, so
pulling the power is harmless. The story behind it is in the blog post:
[daangeijs.nl/posts/birdstation](https://daangeijs.nl/posts/birdstation/).

> **Not hardened.** The RTSP stream (:8554) and the MediaMTX API and metrics
> (:9997, :9998) are open to the whole LAN without authentication or
> encryption, and an outdoor mic can pick up voices. Auth, IP allowlists and
> RTSPS are prepared as variables in `pi/ansible/inventory/group_vars/birdmic.yml`
> (and the BirdNET-Go stream URL comes from a Secret), but they are off by
> default.

## How it fits together

```
 USB headset mic
       |  USB audio (ALSA)
       v
 +-------------------------------+
 | Raspberry Pi 2 "birdmic"      |   read-only root, logs in RAM
 |   ffmpeg -> MediaMTX          |   L16, 48 kHz, mono
 |   rtsp://birdmic:8554/mic     |
 +-------------------------------+
       |  network cable (PoE)
       v
 +-------------------------------+
 | k3s cluster                   |
 |   BirdNET-Go pulls the stream |   BirdNET v3.0 + geomodel range filter
 |   web UI, clips, database     |
 +-------------------------------+
       |  MQTT (auto-discovery)
       v
 Home Assistant
```

The Pi only captures and serves: ffmpeg is the only process that opens the
sound card, MediaMTX starts it and restarts it when it exits, and systemd
restarts MediaMTX. No lossy codec is used anywhere on the audio path. All
the intelligence lives in BirdNET-Go. See
[docs/architecture.md](docs/architecture.md) and
[docs/interface-contract.md](docs/interface-contract.md) for the details
(URLs, audio format, pinned versions).

## Repository layout

| Path | What |
|---|---|
| `pi/image/flash.sh` | Downloads and verifies Raspberry Pi OS Lite (32-bit), writes the SD card with a cloud-init first boot (hostname, user, SSH key, DHCP) |
| `pi/ansible/` | Playbook with the roles `base`, `audio`, `mediamtx`, `readonly` (and `guard`) |
| `k8s/birdnet-go/` | Example BirdNET-Go manifests and config for Kubernetes |
| `scripts/birdmic-status.sh` | Stream up/down check against the MediaMTX API |
| `dev/` | A fake birdmic (looped blackbird recording) for testing without hardware |
| `docs/` | Architecture and interface contract |

## Hardware

- Raspberry Pi 2 Model B. Only the Pi 2 has been tested; the Ansible defaults
  assume it (`birdmic_mediamtx_arch: armv7`, `birdmic_initramfs`), so another
  model needs at least those two changed
- A PoE splitter (802.3af to micro-USB 5 V), so one network cable brings
  power and data to the garden
- Any USB microphone or USB headset. The card is picked by its ALSA name and
  its capture rate is probed, so swapping the mic needs no code change
- A microSD card
- A weatherproof box, and a PoE switch or injector on the other end

## Setup

Everything below uses `birdmic.example.lan` as the Pi's name. Replace it with
your own DNS name or IP address in `pi/ansible/inventory/hosts.yml`, or pass
`BIRDMIC_HOST=...` to the `make` targets.

### 1. Flash the SD card

```sh
make flash-dry PI_DEVICE=/dev/diskN   # dry run: downloads, verifies, shows what it would do
make flash PI_DEVICE=/dev/diskN       # writes the card, asks you to retype the device
```

`flash.sh` pins the image by SHA256 and writes cloud-init settings to the boot
partition: hostname `birdmic`, user `pi` with your `~/.ssh/id_ed25519.pub`,
password login locked, SSH on, wired DHCP. Use `pi/image/flash.sh --help` for
the flags (`--user`, `--ssh-key`, `--timezone`, ...). It refuses the boot
disk, disk images and disks over 256 GB. On macOS it uses the Raspberry Pi
Imager CLI; on Linux Imager if installed, otherwise `xz | dd`.

### 2. Network

Boot the Pi on the cable, give it a DHCP reservation in your router and a
local DNS record. mDNS is switched off on the Pi, so `birdmic.local` will not
work after provisioning. `ssh pi@birdmic.example.lan` should log in without a
password.

### 3. Run Ansible

Plug in the microphone first: the audio role probes it.

```sh
make provision     # cd pi/ansible && ansible-playbook site.yml
make probe         # expect pcm_s16be, 48000, 1
make status        # exit 0 = stream up
```

The playbook upgrades the OS, masks services the station does not need, keeps
the journal in RAM, turns off swap, detects the USB card and sets the capture
gain, installs a pinned and checksum-verified MediaMTX, waits for the stream to
come up, and finally enables the overlay root and reboots. Every setting is in
`pi/ansible/inventory/group_vars/birdmic.yml`. [pi/README.md](pi/README.md)
has the step-by-step version.

### 4. Deploy BirdNET-Go

Set your location, MQTT broker and host name in `k8s/birdnet-go/`, create
the Secret with the stream URL and MQTT password, then:

```sh
kubectl apply -k k8s/birdnet-go
```

Install the BirdNET v3.0 model from the web UI's model gallery afterwards.
[k8s/README.md](k8s/README.md) walks through it.

## Read-only design

The SD card is the weak spot of a Pi that loses power whenever someone trips
over a cable. So the last role, `readonly`, switches on Raspberry Pi OS's
overlay file system (`overlayroot=tmpfs`): the root is mounted read-only and
all writes go to RAM and vanish at reboot. `/boot/firmware` is mounted
read-only too. Logs live in RAM (`Storage=volatile`, 16 MB), swap is off,
cloud-init is disabled after first boot and periodic jobs such as
`apt-daily` and `man-db` are masked.

Running the playbook against a locked Pi changes nothing: it reports that the
root is an overlay and stops, and the `guard` role refuses to run any role
against an overlay root, because the changes would be lost. To change
something:

```sh
make unlock        # ansible-playbook site.yml -e birdmic_readonly=false
                   # disables the overlay, reboots, applies, stays writable
# ...edit group_vars or poke around on the Pi...
make provision     # apply and lock again
```

By hand on the Pi:

```sh
sudo raspi-config nonint disable_overlayfs && sudo reboot
sudo raspi-config nonint disable_bootro       # if /boot/firmware is read-only too
# ...changes...
sudo raspi-config nonint enable_bootro && sudo raspi-config nonint enable_overlayfs && sudo reboot
```

## Tuning notes

These are the choices in `k8s/birdnet-go/config.yaml`, with the reasons from
the comments there. They come from one garden in the Netherlands with a cheap
headset mic, so treat them as a starting point, not as universal truths.

- **BirdNET v3.0 alone, threshold 0.7.** 156 detections were reviewed by
  hand. BirdNET v2.4 on its own was right 3 of 36 times (8%), v3.0 on its own about
  60%, and 22 of 24 v3.0 detections at 0.7 or higher. Below 0.7, reviewed v3.0
  detections were right about half the time; above it, 87 to 100%. So only
  `birdnet_v3.0` is enabled, at a global threshold of 0.7. BirdNET-Go's
  dynamic threshold (on by default) still lets weaker calls of a species
  through for a day once it scored 0.9 or more.
- **Range filter: geomodel v3 at 0.1.** The geomodel scores which species are
  plausible at your location in a given week. Checked against 17,252
  waarneming.nl observations around the station (2021 to 2026), a threshold of
  0.1 blocks only 6 of them (0.01 blocks 4), and it drops summer birds once
  their season is over (in late November Common Quail scores 0.087 and
  Spotted Flycatcher 0.050). That made a long hand-made include list of local
  species, owls and migrants unnecessary.
- **Rarities at 0.85.** Sixteen species on the Dutch list that the geomodel
  never passes here (Boreal Owl, Snowy Owl, European Roller, Alpine Swift,
  Rosy Starling, ...) are force-included, each with a stricter threshold of
  0.85 in `realtime.species.config`. Every key in that section acts as a
  force-include too, so only the rarities are listed there; anything else
  would bypass the seasonal range filter all year.
- **Exclude list.** Escapes, cage birds and species from other continents
  that the geomodel rates just above its cut-off (not on the Dutch list per
  waarneming.nl), plus seals and pelagic birds that never come inland.
  Established exotics such as Egyptian Goose and Rose-ringed Parakeet stay in.
- **200 Hz high-pass.** Mains hum from the mic cable (50 Hz and harmonics up
  to about 250 Hz) was the loudest thing in the stream. A 200 Hz high-pass at
  24 dB/octave removes it and keeps low voices such as owls (300 to 400 Hz)
  and doves (400 to 700 Hz).
- **Privacy.** Detections whose clip contains human speech are dropped (label
  filter at 0.2 plus the Silero VAD gate), and only short clips around
  detections are stored, for 14 days.

## Local development

`dev/` contains a fake birdmic: the official MediaMTX image with ffmpeg loops
a blackbird recording and serves exactly the same stream and API as the Pi.
The recording is downloaded and SHA256-checked at start-up, not committed.

```sh
make dev-up        # docker compose -f dev/docker-compose.yml up -d
make test          # dev-up, then the status script against localhost
make dev-down
```

There is also an in-cluster variant (`kubectl apply -k dev/k8s`) for testing
BirdNET-Go without hardware. See [dev/README.md](dev/README.md).

`make lint` runs shellcheck on the shell scripts and `ansible-playbook
--syntax-check` plus `ansible-lint` on the playbook.

## Thanks

- [BirdNET](https://birdnet.cornell.edu/) by the K. Lisa Yang Center for
  Conservation Bioacoustics (Cornell Lab of Ornithology) and Chemnitz
  University of Technology, for the models that do the actual listening.
- [BirdNET-Go](https://github.com/tphakala/birdnet-go) by Tomi P. Hakala, for
  turning those models into a real-time service with a web UI and MQTT.
- [MediaMTX](https://github.com/bluenviron/mediamtx) by bluenviron, the RTSP
  server on the Pi and in the fake mic.
- [FFmpeg](https://ffmpeg.org/), [Raspberry Pi OS](https://www.raspberrypi.com/software/)
  and [Ansible](https://www.ansible.com/).
- The test recording in `dev/`: "Common Blackbird (Turdus merula) song,
  XC26605 by Sander Pieterse, [xeno-canto](https://xeno-canto.org/26605),
  CC BY-SA 4.0", via Wikimedia Commons. Details in
  [dev/ATTRIBUTION.md](dev/ATTRIBUTION.md).
- [waarneming.nl](https://waarneming.nl/) observations, used to check the
  range filter and the species lists.

## License

MIT, see [LICENSE](LICENSE). The test recording fetched by `dev/` is not part
of this repository and keeps its own licence (CC BY-SA 4.0).
