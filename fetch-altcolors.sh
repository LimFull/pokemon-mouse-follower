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

# Resolve this variant's ROM caster-pose sheet names (indices 2 Strike, 8 Swing,
# 9 Double, 10 Hop, 11 Charge, 12 Rotate) through its AnimData.xml, CopyOf-chased
# — the same set fetch-rom-pose-anims.sh pulls for the base folder. Without these,
# an alt-color follower playing a move whose caster pose is one of them falls back
# to the base (wrong-color) sheet (FollowerBrain.romSheet base fallback).
pose_names() {
  python3 - "$1" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
anims = {}
for m in re.finditer(r'<Anim>\s*<Name>(\w+)</Name>(?:\s*<Index>(-?\d+)</Index>)?'
                     r'(?:\s*<CopyOf>(\w+)</CopyOf>)?', xml):
    anims[m.group(1)] = (int(m.group(2)) if m.group(2) else None, m.group(3))
NEED = {2, 8, 9, 10, 11, 12}
byidx = {idx: name for name, (idx, _) in anims.items() if idx is not None}
out, emitted = [], set()
for idx in sorted(NEED):
    name = byidx.get(idx)
    if not name:
        continue
    seen, target = set(), name           # follow CopyOf to the sheet that ships
    while anims.get(target, (None, None))[1] and target not in seen:
        seen.add(target)
        target = anims[target][1]
    if target not in emitted:
        emitted.add(target)
        out.append(target)
print('\n'.join(out))
PY
}

echo "==> Downloading alt-color sheets into animations/<id>/altcolor/ ..."
count=0
while read -r id dex sub; do
    [ -d "animations/$id" ] || continue
    dst="animations/$id/altcolor"
    mkdir -p "$dst"
    got=0
    # AnimData.xml first — the ROM pose resolution below reads it.
    for f in AnimData.xml \
             Walk-Anim.png Walk-Shadow.png \
             Idle-Anim.png Idle-Shadow.png \
             Sleep-Anim.png Sleep-Shadow.png \
             Faint-Anim.png \
             Attack-Anim.png Hurt-Anim.png Shoot-Anim.png Charge-Anim.png; do
        if curl -fsS -o "$dst/$f" "$RAW/sprite/$dex/$sub/$f" 2>/dev/null; then
            got=1
        else
            rm -f "$dst/$f"
        fi
    done
    # Extended ROM caster-pose sheets, resolved from this variant's AnimData.xml.
    if [ -f "$dst/AnimData.xml" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            f="$name-Anim.png"
            [ -f "$dst/$f" ] && continue          # already fetched (e.g. Charge)
            if curl -fsS -o "$dst/$f" "$RAW/sprite/$dex/$sub/$f" 2>/dev/null; then
                got=1
            else
                rm -f "$dst/$f"
            fi
        done < <(pose_names "$dst/AnimData.xml")
    fi
    if [ "$got" = 1 ]; then
        count=$((count + 1))
        echo "  $id (from sprite/$dex/$sub)"
    else
        rmdir "$dst" 2>/dev/null || true   # declared but empty form
    fi
done < <(manifest)

echo "==> Done. $count characters now have animations/<id>/altcolor/."
