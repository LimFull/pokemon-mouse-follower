"""Shared palette reconstruction for EoS effect WAN sprites.

Effect sprites address palette rows by ABSOLUTE VRAM slot. Each effect file
carries its own rows starting at wan.paletteOffset (usually slots 13-15), but
many frames also reference low slots (0-12) that are owned by *other* files the
game loads into the shared VRAM palette bank at runtime.

We reconstruct a 16-row bank as:  common palette (file 292, the master 16-row
effect palette) for the shared slots, overlaid with THIS effect's own rows at
its paletteOffset. Frames then index it with their raw absolute paletteIndex.

Consequence:
  - "self-contained" effects (every used index falls in the file's own rows)
    render with their EXACT colors.
  - "template" effects (frames reference shared slots) render with the common
    palette's colors -- the shape/timing are exact, but the specific per-move
    tint the game applies at runtime is not recoverable from the sprite alone.
"""

from __future__ import annotations

import os

from skytemple_files.graphics.effect_wan.handler import EffectWanHandler

COMMON_PALETTE_FILE = 292  # master 16-row effect palette in EFFECT/effect.bin

_common_cache = None


def _pad256(row):
    row = list(row)
    if len(row) < 256:
        row = row + [(0, 0, 0, 0)] * (256 - len(row))
    return row


def load_common_rows(effects_dir):
    """16 padded palette rows from the common palette file (cached)."""
    global _common_cache
    if _common_cache is None:
        path = os.path.join(effects_dir, f"effect_{COMMON_PALETTE_FILE:04d}.bin")
        wan = EffectWanHandler.deserialize(open(path, "rb").read())
        rows = [_pad256(r) for r in (wan.customPalette or [])]
        while len(rows) < 16:
            rows.append([(0, 0, 0, 0)] * 256)
        _common_cache = rows
    return [list(r) for r in _common_cache]


def used_palette_indices(wan):
    used = set()
    for mf in wan.frameData:
        if not mf:
            continue
        for uc in mf:
            used.add(uc.paletteIndex)
    return used


def is_self_contained(wan):
    """True if every referenced palette row lives in this file's own rows."""
    if not wan.customPalette:
        return False
    off, n = wan.paletteOffset, len(wan.customPalette)
    used = used_palette_indices(wan)
    return bool(used) and all(off <= u < off + n for u in used)


def apply_reconstructed_palette(wan, effects_dir):
    """Overwrite wan.customPalette with a 16-row bank indexed by absolute
    paletteIndex. Returns True if the effect is self-contained (exact colors),
    False if it borrows shared slots (approximate colors)."""
    self_contained = is_self_contained(wan)
    rows = load_common_rows(effects_dir)
    if wan.customPalette:
        for r, row in enumerate(wan.customPalette):
            slot = wan.paletteOffset + r
            if slot < len(rows) and any(c != (0, 0, 0, 0) for c in row):
                rows[slot] = _pad256(row)
    wan.customPalette = rows
    return self_contained
