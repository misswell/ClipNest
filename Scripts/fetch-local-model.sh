#!/bin/bash
#
# Fetch the local enhancement model (Qwen3-0.6B-4bit) onto a development Mac.
#
# This is a *development* convenience. It is not how the app downloads the model at runtime:
# the app reads a manifest URL from Settings and streams from whatever CDN is configured
# (China plan §4). Production must serve the files from a mainland CDN rather than from
# Hugging Face.
#
# What this script does and does not do:
#
#   - It downloads from `hf-mirror.com`, a mainland-reachable mirror of Hugging Face.
#     Direct `huggingface.co` is unreachable from this network (curl returns 000).
#   - It verifies every file against the digests in `Scripts/model-manifest.qwen3-0.6b-4bit.json`,
#     which were themselves confirmed against Hugging Face's published LFS oids for
#     `model.safetensors` and `tokenizer.json`.
#   - It installs into the app's real model directory and writes the `model-manifest.json`
#     that `LocalModelStore.isInstalled()` reads.
#
# Usage:
#   Scripts/fetch-local-model.sh            # download + verify + install
#   Scripts/fetch-local-model.sh --verify   # re-verify an existing install, no network

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Scripts/model-manifest.qwen3-0.6b-4bit.json"
MIRROR_BASE="${CLIPNEST_MODEL_MIRROR:-https://hf-mirror.com/mlx-community/Qwen3-0.6B-4bit/resolve/main}"
DEST="$HOME/Library/Application Support/ClipNest/Models/qwen3-0.6b-4bit"

[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 1; }

verify() {
    local dir="$1"
    python3 - "$MANIFEST" "$dir" <<'PY'
import hashlib, json, os, sys

manifest, directory = sys.argv[1], sys.argv[2]
data = json.load(open(manifest))
bad, total = [], 0

for entry in data["files"]:
    path = os.path.join(directory, entry["name"])
    total += entry["size"]
    if not os.path.exists(path):
        bad.append(f"{entry['name']}: missing")
        continue
    if os.path.getsize(path) != entry["size"]:
        bad.append(f"{entry['name']}: size {os.path.getsize(path)} != {entry['size']}")
        continue
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(1 << 20):
            h.update(chunk)
    if h.hexdigest() != entry["sha256"]:
        bad.append(f"{entry['name']}: sha256 mismatch")

print(f"  verified {len(data['files']) - len(bad)}/{len(data['files'])} files, {total/1e6:.1f} MB")
for problem in bad:
    print(f"  FAIL {problem}")
sys.exit(1 if bad else 0)
PY
}

if [ "${1:-}" = "--verify" ]; then
    echo "==> Verifying $DEST"
    verify "$DEST"
    echo "==> OK"
    exit 0
fi

mkdir -p "$DEST"
echo "==> Downloading into $DEST"
python3 - "$MANIFEST" <<'PY' > /tmp/clipnest-model-files.txt
import json, sys
for entry in json.load(open(sys.argv[1]))["files"]:
    print(entry["name"])
PY

while read -r name; do
    url="$MIRROR_BASE/$name"
    echo "  --> $name"
    # -C - resumes a partial file, which is what makes a retry cheap.
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 \
         -C - -o "$DEST/$name.part" "$url"
    mv "$DEST/$name.part" "$DEST/$name"
done < /tmp/clipnest-model-files.txt

echo "==> Verifying digests"
verify "$DEST"

# The install record the app reads. Paths are never persisted in UserDefaults (§32).
cp "$MANIFEST" "$DEST/model-manifest.json"

echo "==> Installed. 'ClipNest > Settings > Local enhancement model' should now read 已安装."
echo "    Re-verify any time with: Scripts/fetch-local-model.sh --verify"
