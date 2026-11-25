# Architecture

## Phase 1 (now): pull model

```
EM272 / USB headset
  -> USB audio (ALSA, picked by card name)
  -> Raspberry Pi 2 v1.1 (read-only root, PoE, wired)
       ffmpeg (runOnInit of path "mic")  --RTSP publish, 127.0.0.1-->  MediaMTX
                                                                        :8554 RTSP (TCP)  <-- BirdNET-Go pulls
                                                                        :9997 control API <-- scripts/birdmic-status.sh
                                                                        :9998 metrics     (unused, no Prometheus yet)
k3s (k8s/birdnet-go)
  BirdNET-Go (namespace birdnet-go, local-path PVC)
    -> UI https://birdnet.example.lan
    -> MQTT broker (e.g. the Home Assistant Mosquitto add-on) -> HA auto-discovery
```

Responsibilities:

- **Pi**: capture and serve. No knowledge of the cluster. Survives power cuts thanks to the read-only overlay root; MediaMTX restarts ffmpeg (`runOnInitRestart`) and systemd restarts MediaMTX.
- **BirdNET-Go**: RTSP client, reconnects, inference (BirdNET v3.0 with geomodel v3 range filter), clip retention, privacy filter, MQTT.
- **Monitoring**: one shell script against the MediaMTX API. Prometheus scraping is deferred until the cluster has Prometheus.

Why L16 over RTSP: no lossy codec artifacts in the 2 to 12 kHz band birds use; 770 kbit/s is trivial on wired Ethernet; the Pi 2 only copies samples, it does not encode.

## Phase 2 (later): push to a central relay

```
Pi / ESP32 mic / nest-box camera --RTSP publish--> MediaMTX relay (k8s) <-- BirdNET-Go, recorder, HA, NVR
```

The Pi switches with `birdmic_mode: push` and `birdmic_push_url`. In push mode ffmpeg publishes straight to the relay, and local MediaMTX can be turned off or kept for local diagnostics. BirdNET-Go then points at the relay URL (one Secret value). The relay is not part of this repo yet. The camera (Pi Camera Module 3 NoIR Wide, H.264) and the ESP32 mic become extra MediaMTX paths, so the contract only grows.

## Future options (not in v1)

- Alpine diskless or Buildroot image instead of Raspberry Pi OS Lite + overlayfs.
- Hardening (auth, IP allowlists, nftables, RTSPS, IoT VLAN): see README "NOT HARDENED".
