#!/usr/bin/env python3
"""
Merge the ROM's per-move caster animation index into ../gamedata/moves.json
as `caster_anim` (from out/anim/move_animations.json "animation": the sprite
anim group the USER plays — 0 Walk, 1 Attack, 2 Strike class, 3 Shoot class,
5 Sleep, 7 Idle, 8 Swing, 9 Double, 10 Hop, 11 Charge, 12 Rotate).

Sentinel values outside 0..12 (98/99) are dropped — the playback falls back
to its contact-flag Attack/Shoot heuristic. The playback resolves the index
per species through AnimData.xml (sheets from fetch-rom-pose-anims.sh),
CopyOf chains included.
"""
import json
import os

HERE = os.path.dirname(__file__)
DEST = os.path.abspath(os.path.join(HERE, "..", "gamedata"))

anims = {m["move_id"]: m["animation"]
         for m in json.load(open(os.path.join(HERE, "out", "anim", "move_animations.json")))}
path = os.path.join(DEST, "moves.json")
moves = json.load(open(path))
n = 0
for k, m in moves.items():
    a = anims.get(int(k))
    if a is not None and 0 <= a <= 12:
        m["caster_anim"] = a
        n += 1
    else:
        m.pop("caster_anim", None)
with open(path, "w", encoding="utf-8") as f:
    json.dump(moves, f, ensure_ascii=False, separators=(",", ":"))
print(f"caster_anim merged for {n}/{len(moves)} moves")
