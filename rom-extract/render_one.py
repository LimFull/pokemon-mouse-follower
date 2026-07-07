#!/usr/bin/env python3
"""Render a single effect.bin entry to PNG sheets. Run as a subprocess by render_all.py.

Usage: render_one.py <raw.bin> <entry_dir> <status.json> <used_as_csv> <screen_first:0|1>
Exit codes: 0 = exported, 3 = raw_only (no renderer succeeded).
"""

import json
import os
import sys

from skytemple_files.graphics.effect_wan.handler import EffectWanHandler
from skytemple_files.graphics.effect_wan.sheets import ExportSheets as ExportEffectSheets
from skytemple_files.graphics.effect_screen.handler import ScreenEffectHandler
from skytemple_files.graphics.effect_screen.sheets import ExportSheets as ExportScreenSheets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from effect_palette import apply_reconstructed_palette


def main():
    raw_path, entry_dir, status_path, used_as_csv, screen_first = sys.argv[1:6]
    with open(raw_path, "rb") as f:
        data = f.read()

    info = {
        "index": int(raw_path[-8:-4]),
        "size": len(data),
        "used_as": [t for t in used_as_csv.split(",") if t],
        "exported": "raw_only",
    }
    attempts = ["screen", "wan"] if screen_first == "1" else ["wan", "screen"]
    for kind in attempts:
        try:
            if kind == "wan":
                wan = EffectWanHandler.deserialize(data)
                # Reconstruct a 16-row VRAM palette bank (common palette + this
                # file's own rows) indexed by absolute paletteIndex. Exact for
                # self-contained effects; approximate for runtime-tinted templates.
                exact = apply_reconstructed_palette(wan, os.path.dirname(raw_path))
                info["palette"] = "exact" if exact else "approx_common"
                ExportEffectSheets(entry_dir, wan)
            else:
                screen = ScreenEffectHandler.deserialize(data)
                ExportScreenSheets(entry_dir, screen, True)
            info["exported"] = kind
            break
        except (Exception, MemoryError) as e:
            info["error"] = f"{kind}: {type(e).__name__}"
            continue

    with open(status_path, "w", encoding="utf-8") as f:
        json.dump(info, f)
    sys.exit(0 if info["exported"] != "raw_only" else 3)


if __name__ == "__main__":
    main()
