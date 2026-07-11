#!/bin/bash
set -euo pipefail

# Download the PMD Sprite Collab sheets needed to play each move's ROM caster
# animation (move_animations.json "animation" index -> per-species AnimData
# name, CopyOf-resolved). Complements fetch-battle-anims.sh, which covers the
# fixed Attack/Hurt/Shoot/Charge set; this fetches whatever names the species'
# AnimData maps for indices 2 (Strike class), 8 Swing, 9 Double, 10 Hop,
# 11 Charge, 12 Rotate. Sheets SpriteCollab doesn't have are skipped — the
# playback falls back to the Attack/Shoot heuristic.
#
# Source: PMDCollab/SpriteCollab (folder <id> here maps to 4-digit <NNNN>).

cd "$(dirname "$0")"

python3 - <<'EOF'
import re, os, sys, subprocess
from concurrent.futures import ThreadPoolExecutor

BASE = "https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite"
NEED = {2, 8, 9, 10, 11, 12}

def anim_map(xml):
    anims = {}
    for m in re.finditer(r'<Anim>\s*<Name>(\w+)</Name>(?:\s*<Index>(-?\d+)</Index>)?'
                         r'(?:\s*<CopyOf>(\w+)</CopyOf>)?', xml):
        anims[m.group(1)] = (int(m.group(2)) if m.group(2) else None, m.group(3))
    return anims

jobs = []
for sid in sorted(os.listdir('animations')):
    p = f'animations/{sid}/AnimData.xml'
    if not os.path.isfile(p):
        continue
    anims = anim_map(open(p).read())
    byidx = {idx: name for name, (idx, _) in anims.items() if idx is not None}
    for idx in NEED:
        name = byidx.get(idx)
        if not name:
            continue
        seen, target = set(), name
        while anims.get(target, (None, None))[1] and target not in seen:
            seen.add(target)
            target = anims[target][1]
        dest = f'animations/{sid}/{target}-Anim.png'
        if not os.path.isfile(dest):
            jobs.append((sid, target, dest))

jobs = sorted(set(jobs))
print(f"{len(jobs)} sheets to fetch")

def fetch(job):
    sid, target, dest = job
    url = f"{BASE}/{int(sid):04d}/{target}-Anim.png"
    r = subprocess.run(["curl", "-fsS", "-o", dest, url], capture_output=True)
    if r.returncode != 0:
        try: os.remove(dest)
        except OSError: pass
        return (target, False)
    return (target, True)

ok = miss = 0
with ThreadPoolExecutor(max_workers=12) as ex:
    for target, success in ex.map(fetch, jobs):
        ok += success
        miss += not success

print(f"done: {ok} downloaded, {miss} not on SpriteCollab (skipped)")
EOF
