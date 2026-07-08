#!/usr/bin/env python3
"""
Bundle the move-effect sprites the battle overlay needs (Phase 2d playback).

Resolves every move in ../gamedata/moves.json through the EoS animation tables
(out/anim/move_animations.json + general_animations.json). The move entry's
anim3 is the on-target hit effect (verified: Ember->fire burst file 53,
Gust->wind file 258, ...), so the first nonzero of (anim3, anim1, anim2, anim4)
is used. The general-animation entry then resolves to a sprite file:

  WAN_FILE0 / WAN_FILE1 -> shared effect_0000 / effect_0001, anim_id = unk1
  WAN_OTHER             -> dedicated effect_<anim_file>; unk1 is only sometimes
                           a valid anim_id there (undecoded field), so it's used
                           when valid and the longest animation otherwise
  SCREEN / WBA          -> full-screen effects, skipped (no sprite)

Writes:
  ../gamedata/move_effects.json          move_id -> {file, anim, loop, point}
  ../gamedata/effects/effect_NNNN/       frames/F-*.png + animations.json
                                         (only the ~34 files actually used)
"""
from __future__ import annotations

import json
import os
import shutil

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "out")
DEST = os.path.abspath(os.path.join(HERE, "..", "gamedata"))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def pick_anim(effect_dir, unk1):
    """unk1 when it names a real animation in the file, else the longest one."""
    try:
        anims = load(os.path.join(effect_dir, "animations.json"))["animations"]
    except (OSError, KeyError, ValueError):
        return None
    with_frames = [a for a in anims if a.get("frames")]
    for a in with_frames:
        if a["anim_id"] == unk1:
            return unk1
    best = max(with_frames, key=lambda a: len(a["frames"]), default=None)
    return best["anim_id"] if best else None


def main():
    moves = load(os.path.join(DEST, "moves.json"))
    move_anims = {m["move_id"]: m for m in load(os.path.join(OUT, "anim", "move_animations.json"))}
    general = load(os.path.join(OUT, "anim", "general_animations.json"))

    mapping = {}
    used_files = set()
    skipped = {"screen": 0, "none": 0}
    for key in moves:
        mid = int(key)
        entry = move_anims.get(mid)
        if not entry:
            skipped["none"] += 1
            continue
        # anim3 = on-target hit effect; fall back through the other slots.
        cands = [a for a in (entry["anim3"], entry["anim1"], entry["anim2"], entry["anim4"])
                 if 0 < a < len(general)]
        if not cands:
            # All-zero slots (Tackle & co): the generic strike, effect_0000 anim 0.
            mapping[key] = {"file": 0, "anim": 0, "loop": False, "point": "HEAD"}
            used_files.add(0)
            continue
        g = general[cands[0]]
        t = g.get("anim_type")
        if t in ("WAN_FILE0", "WAN_FILE1"):
            eff, anim = (0 if t == "WAN_FILE0" else 1), g.get("unk1", 0)
        elif t == "WAN_OTHER":
            eff = g.get("anim_file")
            anim = pick_anim(os.path.join(OUT, "effects", f"effect_{eff:04d}"), g.get("unk1"))
            if anim is None:
                skipped["none"] += 1
                continue
        else:  # SCREEN / WBA — no sprite to bundle
            skipped["screen"] += 1
            continue
        point = g.get("point") if g.get("point") not in (None, "NONE") else entry.get("point")
        mapping[key] = {
            "file": eff,
            "anim": anim,
            "loop": bool(g.get("loop")),
            "point": point or "CENTER",
        }
        used_files.add(eff)

    # Copy just the needed effect folders (frames + animations.json).
    eff_dest = os.path.join(DEST, "effects")
    shutil.rmtree(eff_dest, ignore_errors=True)
    total = 0
    for eff in sorted(used_files):
        src = os.path.join(OUT, "effects", f"effect_{eff:04d}")
        dst = os.path.join(eff_dest, f"effect_{eff:04d}")
        os.makedirs(dst, exist_ok=True)
        shutil.copy2(os.path.join(src, "animations.json"), dst)
        fsrc, fdst = os.path.join(src, "frames"), os.path.join(dst, "frames")
        os.makedirs(fdst, exist_ok=True)
        for f in os.listdir(fsrc):
            if f.endswith(".png"):
                shutil.copy2(os.path.join(fsrc, f), fdst)
                total += os.path.getsize(os.path.join(fsrc, f))

    with open(os.path.join(DEST, "move_effects.json"), "w", encoding="utf-8") as f:
        json.dump(mapping, f, ensure_ascii=False, separators=(",", ":"))

    print(f"move_effects.json: {len(mapping)} moves mapped "
          f"(skipped: {skipped['screen']} screen-type, {skipped['none']} unmapped)")
    print(f"effects bundled: {len(used_files)} files, {total / 1e6:.1f} MB of frames")


if __name__ == "__main__":
    main()
