#!/usr/bin/env bash
# Report the state of the birdmic audio stream from the MediaMTX control API.
#
# Rule (docs/interface-contract.md): the stream is "up" when the path is ready
# and its received byte counter grows between two polls about 2 s apart.
#
# Exit codes: 0 up, 1 down, 2 API unreachable or unexpected error.
#
# Usage: birdmic-status.sh [-H host] [-p port] [-n path] [--json]
# Env:   BIRDMIC_HOST, BIRDMIC_API_PORT, BIRDMIC_PATH,
#        BIRDMIC_API_USER / BIRDMIC_API_PASS (optional basic auth)
#
# Field names follow MediaMTX v1.21.4 (GET /v3/paths/get/{name}). There
# "ready", "readyTime" and "bytesReceived" are deprecated aliases of
# "available", "availableTime" and "inboundBytes"; the new names are used
# when present and the old ones otherwise.

set -euo pipefail

host="${BIRDMIC_HOST:-birdmic.example.lan}"
port="${BIRDMIC_API_PORT:-9997}"
path_name="${BIRDMIC_PATH:-mic}"
json=false
poll_interval=2

usage() {
    sed -n '2,11s/^# \{0,1\}//p' "$0"
}

die() {
    echo "birdmic-status: $*" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H | --host) host="${2:?missing value for $1}"; shift 2 ;;
        -p | --port) port="${2:?missing value for $1}"; shift 2 ;;
        -n | --path) path_name="${2:?missing value for $1}"; shift 2 ;;
        --json) json=true; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || die "'$dep' is required but not installed"
done

url="http://${host}:${port}/v3/paths/get/${path_name}"

# Prints the response body followed by a line with the HTTP status code.
# Credentials go through a curl config on stdin so they never show up in ps.
fetch() {
    local auth="" cred
    if [[ -n "${BIRDMIC_API_USER:-}" ]]; then
        cred="${BIRDMIC_API_USER}:${BIRDMIC_API_PASS:-}"
        cred="${cred//\\/\\\\}"
        cred="${cred//\"/\\\"}"
        auth="user = \"${cred}\""
    fi
    printf '%s\n' "$auth" | curl --config - --silent --show-error \
        --connect-timeout 2 --max-time 2.5 \
        --write-out '\n%{http_code}' "$url" 2>&1
}

unreachable() {
    if $json; then
        jq -cn --arg host "$host" --arg path "$path_name" --arg error "$1" \
            '{host: $host, path: $path, verdict: "unreachable", error: $error}'
    else
        echo "birdmic-status: cannot query $url: $1" >&2
    fi
    exit 2
}

# Fetches the path and leaves a normalized JSON object in $snapshot.
poll() {
    local out code body
    if ! out=$(fetch); then
        unreachable "${out%%$'\n'*}"
    fi
    code="${out##*$'\n'}"
    body="${out%$'\n'*}"

    case "$code" in
        200) ;;
        404)
            # MediaMTX is up but the path does not exist: the stream is down.
            snapshot='{"ready": false, "since": null, "source": null, "readers": [], "bytes": 0, "missing": true}'
            return
            ;;
        401 | 403) unreachable "HTTP $code, check BIRDMIC_API_USER/BIRDMIC_API_PASS" ;;
        *) unreachable "HTTP $code from API" ;;
    esac

    snapshot=$(jq -c '{
        ready: (if has("available") then .available else .ready end),
        since: (if has("availableTime") then .availableTime else .readyTime end),
        source: .source.type,
        readers: [.readers[]?.type],
        bytes: (.inboundBytes // .bytesReceived // 0),
        missing: false
    }' <<<"$body" 2>/dev/null) || unreachable "API returned invalid JSON"
}

poll
first="$snapshot"
if [[ $(jq -r .ready <<<"$first") == true ]]; then
    sleep "$poll_interval"
    poll
fi
second="$snapshot"

# Merge both polls into the report and decide the verdict.
report=$(jq -cn --argjson a "$first" --argjson b "$second" \
    --arg host "$host" --arg path "$path_name" --argjson interval "$poll_interval" '{
        host: $host,
        path: $path,
        ready: ($a.ready and $b.ready),
        ready_since: $b.since,
        source: $b.source,
        readers: ($b.readers | length),
        reader_types: ($b.readers | unique),
        bytes_received: $b.bytes,
        bytes_delta: ($b.bytes - $a.bytes),
        poll_interval_s: $interval,
        path_missing: $b.missing
    } | .verdict = (if .ready and .bytes_delta > 0 then "up" else "down" end)')

if $json; then
    echo "$report"
else
    jq -r '
        def yn: if . then "yes" else "no" end;
        "birdmic \(.path) @ \(.host)",
        "  stream ready:   \(.ready | yn)\(if .path_missing then " (path not found)" else "" end)",
        "  ready since:    \(.ready_since // "-")",
        "  source:         \(.source // "-")",
        "  readers:        \(.readers)\(if .readers > 0 then " (\(.reader_types | join(", ")))" else "" end)",
        "  bytes received: \(.bytes_received)\(if .ready then " (+\(.bytes_delta) in \(.poll_interval_s) s)" else "" end)",
        "  verdict:        \(.verdict | ascii_upcase)"
    ' <<<"$report"
fi

[[ $(jq -r .verdict <<<"$report") == up ]]
