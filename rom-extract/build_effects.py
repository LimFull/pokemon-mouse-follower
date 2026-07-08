#!/usr/bin/env python3
"""
Bundle the move-effect sprites the battle overlay needs (Phase 2d playback).

Resolves every move in ../gamedata/moves.json through the EoS animation tables
(out/anim/move_animations.json + general_animations.json). The move entry's
anim3 is the on-target hit effect (verified: Ember->fire burst file 53,
Gust->wind file 258, ...), so the first nonzero of (anim3, anim1, anim2, anim4)
is used. The general-animation entry then resolves to a sprite file:

  WAN_FILE0 / WAN_FILE1 -> shared effect_0000 / effect_0001, anim_id = unk1.
                           These are tiny single PARTICLES the game multiplies
                           at runtime -> flagged "particle" so the app composes
                           a burst of copies.
  WAN_OTHER             -> dedicated effect_<anim_file>. unk1 is unreliable and
                           anim 0 is usually a particle, so the animation with
                           the largest drawn area (bbox over sampled frames) is
                           chosen — that's the actual hit/burst art (verified:
                           53 anim2 = flame burst, 102 anim1 = bubble cluster).
  SCREEN / WBA          -> full-screen effects, skipped (no sprite)

Effects whose palette reconstruction is approximate (effects_index.json
"approx_common", e.g. Bubble rendering pink instead of water-blue) are flagged
"tint": the app re-hues them with the move's type color.

Writes:
  ../gamedata/move_effects.json          move_id -> {file, anim, loop, point}
  ../gamedata/effects/effect_NNNN/       frames/F-*.png + animations.json
                                         (only the ~34 files actually used)
"""
from __future__ import annotations

import json
import os
import shutil

from PIL import Image

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "out")
DEST = os.path.abspath(os.path.join(HERE, "..", "gamedata"))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def pick_anim(effect_dir, unk1):
    """The animation with the largest drawn area (the real burst art). unk1 and
    anim 0 usually name a tiny particle, so a plain index lookup looks wrong."""
    try:
        anims = load(os.path.join(effect_dir, "animations.json"))["animations"]
    except (OSError, KeyError, ValueError):
        return None
    best, best_score = None, -1.0
    for a in anims:
        frames = a.get("frames")
        if not frames:
            continue
        area = 0
        step = max(1, len(frames) // 8)
        for f in frames[::step][:8]:
            p = os.path.join(effect_dir, "frames", f"F-{f['frame']:02d}.png")
            try:
                b = Image.open(p).getbbox()
            except OSError:
                continue
            if b:
                area = max(area, (b[2] - b[0]) * (b[3] - b[1]))
        score = area * (1 + 0.02 * min(len(frames), 30))
        if score > best_score:
            best, best_score = a["anim_id"], score
    return best


def main():
    moves = load(os.path.join(DEST, "moves.json"))
    move_anims = {m["move_id"]: m for m in load(os.path.join(OUT, "anim", "move_animations.json"))}
    general = load(os.path.join(OUT, "anim", "general_animations.json"))
    palette = {e["index"]: e.get("palette")
               for e in load(os.path.join(OUT, "effects", "effects_index.json"))
               if isinstance(e, dict) and "index" in e}

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
        g = general[cands[0]] if cands else None
        t = g.get("anim_type") if g else "WAN_FILE0"   # all-zero slots (Tackle): generic particle hit
        particle = False
        if t in ("WAN_FILE0", "WAN_FILE1"):
            eff, anim = (0 if t == "WAN_FILE0" else 1), (g.get("unk1", 0) if g else 0)
            particle = True
        elif t == "WAN_OTHER":
            eff = g.get("anim_file")
            anim = pick_anim(os.path.join(OUT, "effects", f"effect_{eff:04d}"), g.get("unk1"))
            if anim is None:
                skipped["none"] += 1
                continue
        else:  # SCREEN / WBA — no sprite to bundle
            skipped["screen"] += 1
            continue
        point = (g.get("point") if g and g.get("point") not in (None, "NONE") else None) \
            or entry.get("point") or "CENTER"
        rec = {"file": eff, "anim": anim, "loop": bool(g.get("loop")) if g else False, "point": point}
        if particle:
            rec["particle"] = True
        if particle or palette.get(eff) == "approx_common":
            rec["tint"] = True     # re-hue with the move's type color in-app
        mapping[key] = rec
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
