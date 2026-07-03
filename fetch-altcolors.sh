#!/bin/bash
set -euo pipefail

# Download PMD Sprite Collab "Altcolor" (alternate palette) sprites for every
# character in animations/ that has one. Alt-color forms live in a numbered
# subfolder whose meaning is defined only in the repo's tracker.json, so we read
# that to find each form's path, then fetch its sheets into animations/<id>/altcolor/.
#
# Source: PMDCollab/SpriteCollab (folder <id> here maps to 4-digit <NNNN> there).

cd "$(dirname "$0")"
RAW="https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master"

echo "==> Fetching tracker.json ..."
TRACKER=$(mktemp)
trap 'rm -f "$TRACKER"' EXIT
curl -fsS "$RAW/tracker.json" -o "$TRACKER"

# Emit "<3-digit id> <4-digit dex> <altcolor subpath>" for each roster pokemon
# that declares an Altcolor form.
manifest() {
  python3 - "$TRACKER" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
def walk(node, path=[]):
    for k, v in (node.get("subgroups") or {}).items():
        yield (v.get("name", "") or "", path + [k])
        yield from walk(v, path + [k])
for i in range(1, 252):
    dex = f"{i:04d}"
    if dex not in t:
        continue
    for name, p in walk(t[dex]):
        if name.lower() == "altcolor":
            print(f"{i:03d} {dex} {'/'.join(p)}")
            break
PY
}

echo "==> Downloading alt-color sheets into animations/<id>/altcolor/ ..."
count=0
while read -r id dex sub; do
    [ -d "animations/$id" ] || continue
    dst="animations/$id/altcolor"
    mkdir -p "$dst"
    got=0
    for f in AnimData.xml \
             Walk-Anim.png Walk-Shadow.png \
             Idle-Anim.png Idle-Shadow.png \
             Sleep-Anim.png Sleep-Shadow.png; do
        if curl -fsS -o "$dst/$f" "$RAW/sprite/$dex/$sub/$f" 2>/dev/null; then
            got=1
        else
            rm -f "$dst/$f"
        fi
    done
    if [ "$got" = 1 ]; then
        count=$((count + 1))
        echo "  $id (from sprite/$dex/$sub)"
    else
        rmdir "$dst" 2>/dev/null || true   # declared but empty form
    fi
done < <(manifest)

echo "==> Done. $count characters now have animations/<id>/altcolor/."
