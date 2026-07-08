#!/bin/bash
set -euo pipefail

# Download the PMD Sprite Collab "Faint" animation sheet for every character in
# animations/. Used to play a proper faint animation (and hold its last frame)
# when a Pokémon is knocked out in raising mode.
#
# Source: PMDCollab/SpriteCollab (folder <id> here maps to 4-digit <NNNN> there).

cd "$(dirname "$0")"
BASE="https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite"

count=0
for dir in animations/*/; do
  id=$(basename "$dir")
  [ -f "animations/$id/Walk-Anim.png" ] || continue
  four=$(printf "%04d" "$((10#$id))")
  url="$BASE/$four/Faint-Anim.png"
  if curl -fsS -o "animations/$id/Faint-Anim.png" "$url" 2>/dev/null; then
    count=$((count + 1))
  else
    rm -f "animations/$id/Faint-Anim.png"
    echo "  $id  (no Faint sheet, skipped)"
  fi
done
echo "Downloaded Faint-Anim.png for $count characters."
