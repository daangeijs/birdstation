# BirdNET-Go on k3s

An example of how BirdNET-Go runs next to the Pi: plain manifests plus a
kustomization in [`birdnet-go/`](birdnet-go/). It is the setup this station
runs with, with the host names, location, MQTT broker and secrets replaced by
placeholders. Any Kubernetes cluster works; nothing here is k3s specific
except the defaults for the ingress class (`traefik`) and storage class
(`local-path`).

Image: `ghcr.io/tphakala/birdnet-go:20261031` (amd64 and arm64).

## Files

| File | What it does |
|---|---|
| `namespace.yaml` | Namespace `birdnet-go`. |
| `config.yaml` | The BirdNET-Go config (location, threshold, model, range filter, species lists, RTSP stream, high-pass filter, privacy filter, clip retention, MQTT + Home Assistant discovery). Turned into a ConfigMap by `kustomization.yaml`; an edit rolls the pod. |
| `deployment.yaml` | One replica, `Recreate`. An init container copies `config.yaml` to `/config/config.yaml` and fills in the RTSP URL and MQTT password from the Secret, then BirdNET-Go starts. Probes on `/health` (port 8080). |
| `pvc.yaml` | 20Gi volume: `config/` subPath on `/config`, `data/` subPath on `/data` (SQLite database, clips, gallery models). |
| `service.yaml`, `ingress.yaml` | The web UI on port 8080, exposed as `birdnet.example.lan`. |
| `secret.example.yaml` | Template for Secret `birdnet-go-env` (`RTSP_URL`, `MQTT_PASSWORD`). Not in the kustomization. |
| `kustomization.yaml` | Ties it together. |

BirdNET-Go saves settings from the web UI into its config file, but the init
container rewrites that file on every start. UI changes are therefore
temporary: make lasting changes in `config.yaml`.

## Before the first deploy

1. In `config.yaml`, set at least:
   - `birdnet.latitude` / `birdnet.longitude` (the example is a round
     placeholder, 52.0 / 5.8; the range filter depends on it),
   - `birdnet.locale` (language of the species names),
   - `realtime.mqtt.broker` and `username`, or `realtime.mqtt.enabled: false`,
   - `security.baseurl`, and `realtime.species` (the lists are tuned for the
     Netherlands, see the main README).
2. In `ingress.yaml`, set your host name (and TLS if you want it).
3. Create the Secret (see `secret.example.yaml`):

   ```sh
   kubectl create namespace birdnet-go
   kubectl -n birdnet-go create secret generic birdnet-go-env \
     --from-literal=RTSP_URL=rtsp://birdmic.example.lan:8554/mic \
     --from-literal=MQTT_PASSWORD='<your MQTT password>'
   ```

   The pod stays in `Init` until the Secret has both keys; the init container
   refuses to start with an empty value.

4. Deploy:

   ```sh
   kubectl kustomize k8s/birdnet-go     # render (make k8s-render)
   kubectl apply -k k8s/birdnet-go
   ```

## Models

`config.yaml` enables only BirdNET v3.0 (`birdnet_v3.0`, the regional
central-europe model) and uses geomodel v3 as range filter. Both are gallery
downloads, not part of the image:

1. Open the web UI, Settings > Models, and install BirdNET v3.0. The files land
   in `/data/models` on the volume.
2. Check the paths the gallery used and compare them with `birdnetv3:` and
   `birdnet.rangefilter` in `config.yaml`:

   ```sh
   kubectl -n birdnet-go exec deploy/birdnet-go -- find /data/models -name '*.onnx' -o -name '*labels*'
   kubectl -n birdnet-go exec deploy/birdnet-go -- cat /config/config.yaml
   ```

3. Copy any differences into `config.yaml` and apply again (a UI install only
   writes `/config/config.yaml`, which the next restart overwrites).

To run v2.4 next to v3.0 for comparison, add `birdnet` to `models.enabled`.

## Testing against the fake mic (`dev/`)

Point `RTSP_URL` in the Secret at the fake mic, for example
`rtsp://<host running dev/>:8554/mic` or, for the in-cluster variant,
`rtsp://fake-birdmic.birdmic-dev.svc.cluster.local:8554/mic`, then restart:

```sh
kubectl -n birdnet-go create secret generic birdnet-go-env \
  --from-literal=RTSP_URL=rtsp://<fake-mic-host>:8554/mic \
  --from-literal=MQTT_PASSWORD='<your MQTT password>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n birdnet-go rollout restart deploy/birdnet-go
```

The host must be reachable from the cluster (LAN IP, not localhost). Set
`RTSP_URL` back to the Pi when done.
