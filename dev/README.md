# Fake birdmic

A stand-in for the Pi that serves exactly the contract stream from
`docs/interface-contract.md`:

- `rtsp://<host>:8554/mic`, RTSP over TCP, L16 (`pcm_s16be`), 48000 Hz, mono
- MediaMTX control API on `:9997` (`/v3/paths/get/mic`)

It runs the official MediaMTX v1.21.4 image with ffmpeg bundled
(`bluenviron/mediamtx:1.21.4-ffmpeg`, pinned by its multi-arch digest: amd64,
arm64, arm/v7, arm/v6) and loops a real blackbird recording. See
`ATTRIBUTION.md` for the recording and its licence.

```
dev/
  config/mediamtx.yml      MediaMTX config, shared by both variants
  config/fetch-audio.sh    downloads + SHA256-checks the recording, converts it to bird.wav
  config/kustomization.yaml  turns the two files above into a ConfigMap
  docker-compose.yml       variant 1: on the Mac
  k8s/                     variant 2: inside the cluster (namespace birdmic-dev)
```

The audio is fetched at start-up instead of being committed (the WAV is about
8.8 MB). The script checks the SHA256 of the download and refuses to continue
on a mismatch.

## Variant 1: on the Mac (Docker Desktop, Colima or OrbStack)

```sh
docker compose -f dev/docker-compose.yml up -d
docker compose -f dev/docker-compose.yml logs -f      # first run downloads the recording
docker compose -f dev/docker-compose.yml down         # add -v to also drop the audio volume
```

The `fetch-audio` one-shot service fills a named volume, then `fake-birdmic`
starts MediaMTX. Ports 8554 and 9997 are published on all interfaces, so
BirdNET-Go in the cluster can pull the stream from the Mac:

```sh
ipconfig getifaddr en0          # Mac LAN IP, use en1 or similar if on another interface
# BirdNET-Go RTSP URL: rtsp://<mac-lan-ip>:8554/mic
```

Colima 0.10 forwards published ports through ssh, listening on all IPv4
interfaces (`lsof -nP -iTCP:8554 -sTCP:LISTEN` shows `*:8554`), which is enough
since everything here is TCP. If the cluster cannot connect, check the macOS
firewall and whether the Mac's VLAN may reach the cluster nodes' VLAN.

## Variant 2: inside the cluster

```sh
kubectl kustomize dev/k8s                      # render
kubectl apply --dry-run=client -k dev/k8s      # validate
kubectl apply -k dev/k8s                       # run
kubectl -n birdmic-dev logs deploy/fake-birdmic -c fetch-audio
```

An initContainer downloads and checks the recording into an `emptyDir`, the
MediaMTX config comes from a generated ConfigMap. The pod runs as non-root with a
read-only root filesystem. Point BirdNET-Go at:

```
rtsp://fake-birdmic.birdmic-dev.svc.cluster.local:8554/mic
```

The initContainer needs outbound HTTPS to upload.wikimedia.org (fallback
xeno-canto.org). Remove everything again with `kubectl delete -k dev/k8s`.

## Verify

Stream format:

```sh
ffprobe -hide_banner -rtsp_transport tcp rtsp://localhost:8554/mic
# Stream #0:0: Audio: pcm_s16be, 48000 Hz, mono, s16, 768 kb/s
```

Status, using the same script that watches the real Pi:

```sh
scripts/birdmic-status.sh -H localhost            # expect verdict UP, exit 0
scripts/birdmic-status.sh -H localhost -n nope    # unknown path, verdict DOWN, exit 1
docker compose -f dev/docker-compose.yml stop
scripts/birdmic-status.sh -H localhost            # API unreachable, exit 2
```

For the cluster variant, port-forward first:

```sh
kubectl -n birdmic-dev port-forward svc/fake-birdmic 8554 9997
```

Listen to it:

```sh
ffplay -rtsp_transport tcp rtsp://localhost:8554/mic
```
