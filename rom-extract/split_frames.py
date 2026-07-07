#!/usr/bin/env python3
"""Render every effect's metaframes as individual PNGs plus animation metadata.

For each effect_NNNN.bin that parses as a WAN sprite, writes into
out/effects/effect_NNNN/:
    frames/F-00.png, F-01.png, ...   individual composed frames (same size)
    animations.json                  [{anim_id, frames:[{frame, duration, offset}]}]
frame  = index into frames/          duration = game frames at 60 fps

Usage: split_frames.py [--out out]
"""

import argparse
import json
import os
import sys

from skytemple_files.graphics.effect_wan.handler import EffectWanHandler
from skytemple_files.graphics.effect_wan import sheets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from effect_palette import apply_reconstructed_palette


def log(msg):
    print(msg, flush=True)


def split_effect(bin_path, entry_dir):
    with open(bin_path, "rb") as f:
        data = f.read()
    wan = EffectWanHandler.deserialize(data)
    apply_reconstructed_palette(wan, os.path.dirname(bin_path))

    if wan.imgType == 3 or not wan.frameData:
        return 0, 0  # atlas-only or empty: nothing to split

    # Same shared bounding box the sheet exporter uses (pass 2)
    min_box = (10000, 10000, -1, -1)
    for mf in wan.frameData:
        for uc in mf:
            rect = sheets.GetPieceRect(wan, uc)
            if rect is not None:
                min_box = sheets.CombineExtents(min_box, rect)
    if min_box[2] < 0:
        return 0, 0
    min_box = sheets.roundUpBox(min_box)

    frames_dir = os.path.join(entry_dir, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    n_frames = 0
    for i, mf in enumerate(wan.frameData):
        img = sheets.GenerateFrame(wan, mf, min_box)
        if img is not None:
            img.save(os.path.join(frames_dir, f"F-{i:02d}.png"))
            n_frames += 1

    anims = []
    for a, seq in enumerate(wan.animData):
        anims.append(
            {
                "anim_id": a,
                "frames": [
                    {
                        "frame": int(sf.frmIndex),
                        "duration": int(sf.duration),
                        "offset": [int(sf.offset[0]), int(sf.offset[1])],
                    }
                    for sf in seq
                ],
            }
        )
    with open(os.path.join(entry_dir, "animations.json"), "w", encoding="utf-8") as f:
        json.dump(
            {"frame_size": [min_box[2] - min_box[0], min_box[3] - min_box[1]], "animations": anims},
            f,
            ensure_ascii=False,
            indent=2,
        )
    return n_frames, len(anims)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
    args = ap.parse_args()

    effects_dir = os.path.join(args.out, "effects")
    with open(os.path.join(effects_dir, "effects_index.json"), encoding="utf-8") as f:
        index = json.load(f)

    done = skipped = failed = 0
    for entry in index:
        if entry.get("exported") != "wan":
            skipped += 1
            continue
        i = entry["index"]
        try:
            n_frames, n_anims = split_effect(
                os.path.join(effects_dir, f"effect_{i:04d}.bin"),
                os.path.join(effects_dir, f"effect_{i:04d}"),
            )
            if n_frames:
                done += 1
            else:
                skipped += 1
        except Exception as e:
            failed += 1
            log(f"  ! effect {i:04d}: {type(e).__name__}: {str(e)[:60]}")
        if (done + skipped + failed) % 50 == 0:
            log(f"  {done + skipped + failed}/{len(index)}...")

    log(f"frames split: {done} effects done, {skipped} skipped (no frames/not wan), {failed} failed")


if __name__ == "__main__":
    main()
