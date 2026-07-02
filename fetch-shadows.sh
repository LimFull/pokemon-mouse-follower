#!/bin/bash
set -euo pipefail

# Download PMD Sprite Collab shadow-marker sheets for every character already in
# animations/. Each <Anim>-Shadow.png marks, per frame, the shadow's ground
# position (a single white center pixel) and the small/medium/large footprint
# (nested blue/red/green regions). Used to place the ground shadow correctly.
#
# Source: PMDCollab/SpriteCollab (folder <id> here maps to 4-digit <NNNN> there).

cd "$(dirname "$0")"
BASE="https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite"

fetch() {
  local dir="$1" id four url
  id="$dir"
  four=$(printf "%04d" "$((10#$id))")
  for anim in Walk Idle Sleep; do
    # Only fetch a shadow sheet when the matching color sheet is present.
    [ -f "animations/$id/$anim-Anim.png" ] || continue
    url="$BASE/$four/$anim-Shadow.png"
    if curl -fsS -o "animations/$id/$anim-Shadow.png" "$url" 2>/dev/null; then
      echo "  $id/$anim-Shadow.png"
    else
      rm -f "animations/$id/$anim-Shadow.png"
      echo "  $id/$anim-Shadow.png  (missing, skipped)"
    fi
  done
}
export -f fetch
export BASE

echo "==> Fetching shadow sheets into animations/ ..."
ls animations | sort | xargs -P 8 -I {} bash -c 'fetch "$@"' _ {}
echo "==> Done. $(find animations -name '*-Shadow.png' | wc -l | tr -d ' ') shadow sheets."
