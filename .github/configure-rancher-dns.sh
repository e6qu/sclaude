#!/usr/bin/env bash
# Configure only the fresh Rancher VM provisioned by the hosted CI job.
set -euo pipefail
: "${RDCTL:?Rancher Desktop CLI required}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$RDCTL" shell sudo cat /etc/docker/daemon.json > "$work/original.json"
python3 - "$work/original.json" "$work/configured.json" <<'PY'
import json
import sys
from pathlib import Path

config = json.loads(Path(sys.argv[1]).read_text())
config['dns'] = ['1.1.1.1', '8.8.8.8']
Path(sys.argv[2]).write_text(json.dumps(config) + '\n')
PY
"$RDCTL" shell sudo tee /etc/docker/daemon.json < "$work/configured.json" > /dev/null
"$RDCTL" shell sudo rc-service docker restart
for _ in $(seq 1 24); do
    if docker info > /dev/null 2>&1; then exit 0; fi
    sleep 5
done
printf 'Rancher Docker did not become ready after its DNS configuration restart\n' >&2
exit 1
