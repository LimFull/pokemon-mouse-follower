#!/usr/bin/env python3
"""
Bundle the move-effect sprites the battle overlay needs (Phase 2d playback).

Resolves every move in ../gamedata/moves.json through the EoS animation tables
(out/anim/move_animations.json + general_animations.json). Slot semantics
(verified against known moves):
  anim3 = the on-target HIT effect (Ember->flame burst, Bubble->bubble pop,
          Thunderbolt->lightning strike). First nonzero of (anim3, anim1,
          anim2, anim4) is the hit.
  anim4 = the PROJECTILE / travel effect (Bubble->three flying bubbles,
          Water Gun->water stream, Razor Leaf->flying leaves; usually loop).
          Exported as "proj" so the app can fly it attacker->target first.
The general-animation entry then resolves to a sprite file:

  The animation within the file is selected by the general entry's **unk2**
  for every WAN type (decoded 2026-07-08, correcting the README's old unk1
  claim): FILE1's 26 entries enumerate unk2 0..25 exactly once, FILE0's span
  0..49 (= its 50 sequences), and every WAN_OTHER unk2 names a non-empty
  sequence — including semantic matches like the three powders (Stun/Poison/
  Sleep -> 0/1/2), Yawn -> the single drifting bubble, Bubble -> the bubble
  cluster. unk1 (mostly 14) is something else.

  WAN_FILE0 / WAN_FILE1 -> shared effect_0000 / effect_0001: tiny single
                           PARTICLES the game multiplies at runtime ->
                           flagged "particle" so the app composes a burst.
  WAN_OTHER             -> dedicated effect_<anim_file>, sequence = unk2
                           (largest-drawn-area fallback if ever invalid).
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


def pick_anim(effect_dir, unk2):
    """The ROM-selected sequence (unk2); largest-drawn-area fallback if that
    ever names an empty/missing sequence."""
    try:
        anims = load(os.path.join(effect_dir, "animations.json"))["animations"]
    except (OSError, KeyError, ValueError):
        return None
    for a in anims:
        if a["anim_id"] == unk2 and a.get("frames"):
            return unk2
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

    def resolve(g):
        """General entry -> {file, anim, loop, particle?, tint?} or None (screen/invalid)."""
        t = g.get("anim_type") if g else "WAN_FILE0"
        particle = False
        if t in ("WAN_FILE0", "WAN_FILE1"):
            eff, anim = (0 if t == "WAN_FILE0" else 1), (g.get("unk2", 0) if g else 0)
            particle = True
        elif t == "WAN_OTHER":
            eff = g.get("anim_file")
            anim = pick_anim(os.path.join(OUT, "effects", f"effect_{eff:04d}"), g.get("unk2"))
            if anim is None:
                return None
            # 8-direction sets: unk2 on a multiple of 8 with 8 consecutive
            # non-empty sequences = one rotation per facing (projectiles).
            if anim == g.get("unk2") and anim % 8 == 0:
                try:
                    anims = {a["anim_id"]: len(a.get("frames") or [])
                             for a in load(os.path.join(OUT, "effects", f"effect_{eff:04d}",
                                                        "animations.json"))["animations"]}
                    if all(anims.get(anim + i, 0) > 0 for i in range(8)):
                        rec_dirs = True
                    else:
                        rec_dirs = False
                except (OSError, KeyError, ValueError):
                    rec_dirs = False
            else:
                rec_dirs = False
        else:  # SCREEN / WBA — a full-screen effect; the app renders a
            return {"screen": True}   # type-colored flash + quake instead
        rec = {"file": eff, "anim": anim, "loop": bool(g.get("loop")) if g else False}
        if t == "WAN_OTHER" and rec_dirs:
            rec["dirs"] = True
        if particle:
            rec["particle"] = True
        if particle or palette.get(eff) == "approx_common":
            rec["tint"] = True     # re-hue with the move's type color in-app
        return rec

    mapping = {}
    used_files = set()
    skipped = {"screen": 0, "none": 0}
    n_proj = 0
    n_co = 0
    for key in moves:
        mid = int(key)
        entry = move_anims.get(mid)
        if not entry:
            skipped["none"] += 1
            continue
        # Hit effect: anim3 first, falling back through anim1/anim2 — but
        # NEVER anim4: that slot is the projectile, and moves whose only
        # visual is anim4 (Barrage & co) must FLY it, not park it on the
        # target (the generic particle spark covers the impact).
        slots = (entry["anim3"], entry["anim1"], entry["anim2"])
        cands = [a for a in slots if 0 < a < len(general)]
        hit_slot = cands[0] if cands else None
        rec = resolve(general[hit_slot] if hit_slot is not None else None)
        if rec is None:
            skipped["none"] += 1
            continue
        g = general[hit_slot] if hit_slot is not None else None
        rec["point"] = (g.get("point") if g and g.get("point") not in (None, "NONE") else None) \
            or entry.get("point") or "CENTER"
        # Projectile: the anim4 slot, when present and not already used as the hit.
        a4 = entry["anim4"]
        if not rec.get("screen") and 0 < a4 < len(general) and a4 != hit_slot:
            proj = resolve(general[a4])
            if proj is not None and not proj.get("screen"):
                rec["proj"] = proj
                used_files.add(proj["file"])
                n_proj += 1
        # Companion: the anim2 slot when it isn't already the hit or the
        # projectile — the visual the hit-slot priority used to DROP (e.g.
        # Vine Whip: anim3 is just the impact flash, anim2 is the vine lash
        # itself). Played at the target right before the hit clip.
        a2 = entry["anim2"]
        if not rec.get("screen") and 0 < a2 < len(general) and a2 not in (hit_slot, a4):
            co = resolve(general[a2])
            if co is not None and not co.get("screen") \
               and (co["file"], co["anim"]) != (rec.get("file"), rec.get("anim")):
                rec["co"] = co
                used_files.add(co["file"])
                n_co += 1
        mapping[key] = rec
        if "file" in rec:
            used_files.add(rec["file"])

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

    print(f"move_effects.json: {len(mapping)} moves mapped, {n_proj} with a projectile, "
          f"{n_co} with a companion "
          f"(skipped: {skipped['screen']} screen-type, {skipped['none']} unmapped)")
    print(f"effects bundled: {len(used_files)} files, {total / 1e6:.1f} MB of frames")


if __name__ == "__main__":
    main()
