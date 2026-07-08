#!/bin/bash
set -euo pipefail

# Download the PMD Sprite Collab battle-pose sheets (Attack / Hurt / Shoot /
# Charge, design D2-1) for every character in animations/. Used by raising-mode
# battles: the attacker plays Attack (Shoot for projectile moves), the defender
# plays Hurt while damage lands. Missing sheets are skipped (code falls back).
#
# Source: PMDCollab/SpriteCollab (folder <id> here maps to 4-digit <NNNN> there).

cd "$(dirname "$0")"
BASE="https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite"

for anim in Attack Hurt Shoot Charge; do
  count=0
  missing=0
  for dir in animations/*/; do
    id=$(basename "$dir")
    [ -f "animations/$id/Walk-Anim.png" ] || continue
    [ -f "animations/$id/$anim-Anim.png" ] && { count=$((count + 1)); continue; }
    four=$(printf "%04d" "$((10#$id))")
    if curl -fsS -o "animations/$id/$anim-Anim.png" "$BASE/$four/$anim-Anim.png" 2>/dev/null; then
      count=$((count + 1))
    else
      rm -f "animations/$id/$anim-Anim.png"
      missing=$((missing + 1))
    fi
  done
  echo "$anim: $count downloaded/present, $missing missing"
done
