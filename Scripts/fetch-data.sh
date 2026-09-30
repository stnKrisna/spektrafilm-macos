#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.3.3}"
REPO="${SPEKTRAFILM_DATA_REPO:-darktable-org/darktable-spektrafilm}"
REF="${SPEKTRAFILM_DATA_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Data"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/spektrafilm-data.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }

MANIFEST="$TMP/manifest.json"
PACK_META="$TMP/pack-meta.json"

fetch() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  curl --fail --location --silent --show-error \
       --retry 3 --retry-delay 1 --retry-all-errors \
       "$url" --output "$out"
}

echo "Fetching Spektrafilm data manifest from ${REPO}@${REF}..."
fetch "$RAW_BASE/manifest.json" "$MANIFEST"

python3 - "$MANIFEST" "$VERSION" "$PACK_META" <<'PY'
import json, pathlib, sys
manifest_path, version, out_path = sys.argv[1:]
data = json.loads(pathlib.Path(manifest_path).read_text())

matches = [p for p in data.get("packs", []) if p.get("spektrafilm_version") == version]
if not matches:
    available = ", ".join(sorted({str(p.get("spektrafilm_version")) for p in data.get("packs", [])}))
    raise SystemExit(f"error: Spektrafilm pack {version!r} not found; available: {available or '(none)'}")
if len(matches) != 1:
    raise SystemExit(f"error: manifest contains {len(matches)} packs for version {version!r}")

pack = matches[0]
required = ("base", "lut_hash", "pack_format", "files")
missing = [key for key in required if key not in pack]
if missing:
    raise SystemExit(f"error: malformed manifest entry; missing: {', '.join(missing)}")

pathlib.Path(out_path).write_text(json.dumps(pack))
print(f"Selected pack {version}: LUT {pack['lut_hash']} ({len(pack['files'])} files)")
PY

PACK_BASE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base"])' "$PACK_META")"
STAGE="$TMP/Data"
mkdir -p "$STAGE"

python3 - "$PACK_META" <<'PY' > "$TMP/files.tsv"
import json, sys
for item in json.load(open(sys.argv[1]))["files"]:
    path = item.get("path")
    sha = item.get("sha256")
    size = item.get("size")
    if not path or not sha or size is None:
        raise SystemExit("error: every manifest file must have path, size, and sha256")
    if path.startswith("/") or ".." in path.split("/"):
        raise SystemExit(f"error: unsafe path in manifest: {path!r}")
    print(f"{path}\t{size}\t{sha}")
PY

count=0
while IFS=$'\t' read -r rel expected_size expected_sha; do
  count=$((count + 1))
  echo "[$count] Downloading $rel"
  out="$STAGE/$rel"
  fetch "$RAW_BASE/$PACK_BASE/$rel" "$out"

  python3 - "$out" "$expected_size" "$expected_sha" <<'PY'
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
expected_size = int(sys.argv[2])
expected_sha = sys.argv[3].lower()
data = path.read_bytes()
actual_sha = hashlib.sha256(data).hexdigest()
if len(data) != expected_size:
    raise SystemExit(f"error: size mismatch for {path.name}: expected {expected_size}, got {len(data)}")
if actual_sha != expected_sha:
    raise SystemExit(f"error: SHA-256 mismatch for {path.name}: expected {expected_sha}, got {actual_sha}")
PY
done < "$TMP/files.tsv"

# Keep the data license and packaging changelog next to downloaded data.
echo "Downloading license and attribution files..."
fetch "$RAW_BASE/LICENSE" "$STAGE/SPEKTRAFILM_DATA_LICENSE.txt"
# CHANGELOG is useful attribution/context but is not required for a usable pack.
if curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 1 --retry-all-errors \
        "$RAW_BASE/CHANGELOG.txt" --output "$STAGE/SPEKTRAFILM_DATA_CHANGELOG.txt"; then
  :
else
  rm -f "$STAGE/SPEKTRAFILM_DATA_CHANGELOG.txt"
  echo "warning: upstream CHANGELOG.txt was not available" >&2
fi

# Record exactly what was installed.
python3 - "$PACK_META" "$REPO" "$REF" > "$STAGE/INSTALL.json" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
print(json.dumps({
    "source_repository": sys.argv[2],
    "source_ref": sys.argv[3],
    "spektrafilm_version": meta.get("spektrafilm_version"),
    "lut_id": meta.get("lut_id"),
    "lut_hash": meta.get("lut_hash"),
    "pack_format": meta.get("pack_format"),
}, indent=2, sort_keys=True))
PY

# Only replace the installed pack after every manifest-listed file passed verification.
mkdir -p "$DEST"
rm -rf "$DEST/profiles"
rm -f "$DEST/pack.json" "$DEST/spectra_lut.f32" \
      "$DEST/SPEKTRAFILM_DATA_LICENSE.txt" "$DEST/SPEKTRAFILM_DATA_CHANGELOG.txt" \
      "$DEST/INSTALL.json"
cp -R "$STAGE"/. "$DEST"/

echo
echo "Spektrafilm ${VERSION} data installed successfully in:"
echo "  $DEST"
echo "Verified all manifest-listed files with SHA-256."
echo "Data license: $DEST/SPEKTRAFILM_DATA_LICENSE.txt"
