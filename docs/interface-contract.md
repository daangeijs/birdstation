# Interface contract

Authoritative. All parts (k8s, Pi, monitoring, fake mic) build against this file. Change it here first, then in the code. Host names are examples: replace `birdmic.example.lan` and `birdnet.example.lan` with your own.

## Endpoints and format

| Item | Value |
|---|---|
| Pi hostname | `birdmic.example.lan` (DHCP reservation plus a local DNS record that the cluster pods can resolve too). Ansible var `birdmic_fqdn`. |
| Pi board | Raspberry Pi 2 Model B v1.1 (BCM2836), Raspberry Pi OS Lite 32-bit (armhf) |
| Audio stream | `rtsp://birdmic.example.lan:8554/mic`, RTSP over TCP |
| Audio format | L16 (`pcm_s16be`), 48000 Hz, 1 channel (about 770 kbit/s), RTP payload L16/48000/1 |
| Pi status API | MediaMTX control API, `http://birdmic.example.lan:9997/v3/paths/get/mic` (JSON: `available`, `availableTime`, `readers[]`, `inboundBytes`, `source`; the older `ready`, `readyTime`, `bytesReceived` are deprecated aliases in v1.21.4). MediaMTX only allows the API from localhost by default, so the Pi config grants `api` to any IP during the prototype. |
| Pi metrics | MediaMTX Prometheus metrics, `http://birdmic.example.lan:9998/metrics` (no Prometheus in the cluster yet, unused) |
| BirdNET-Go UI | `https://birdnet.example.lan` (Traefik Ingress; add TLS yourself) |
| Detections out | BirdNET-Go UI + MQTT to your broker (e.g. the HA Mosquitto add-on), user `birdnet`, HA auto-discovery |
| Location | Your own coordinates in `k8s/birdnet-go/config.yaml` (placeholder 52.0 N, 5.8 E), timezone Europe/Amsterdam |

## Pinned versions

| Component | Version | Notes |
|---|---|---|
| MediaMTX | v1.21.4 | `linux_armv7` on Pi, official image in `dev/`. Checksums verified from release `checksums.sha256`. |
| BirdNET-Go | release 20261031 | Container image tag in `k8s/birdnet-go`. Model: BirdNET v3.0 (central-europe, gallery download) with geomodel v3 range filter. |
| Raspberry Pi OS Lite | armhf, version pinned in `pi/image/flash.sh` | SHA256 from downloads.raspberrypi.com |

## Status semantics

Stream "up" means `available == true` and `inboundBytes` keeps growing between two polls. Anything else is "down". `scripts/birdmic-status.sh` uses this rule, and exits non-zero when the stream is down.

## Rules

- The Pi runs only ffmpeg + MediaMTX. No custom code, no web UI.
- ffmpeg is the only process that opens the ALSA capture device. The device is picked by name (ALSA `CARD=<name>`), never by card index.
- No lossy codecs anywhere on the audio path.
- Prototype: RTSP, API and metrics are unauthenticated on the LAN. Every auth/TLS/firewall setting is a variable (Ansible `birdmic_auth_*`, `birdmic_rtsp_encryption`; BirdNET-Go URL comes from a Secret), so hardening is a config change.
- Phase 2 (push to a relay in k8s) is a single switch: Ansible `birdmic_mode: serve | push` plus `birdmic_push_url`. In `push` mode, ffmpeg publishes to the relay instead of the local MediaMTX.
