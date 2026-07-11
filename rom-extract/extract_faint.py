#!/usr/bin/env python3
"""
Extract a species' Faint animation from the ROM into animations/<id>/.

SpriteCollab ships Faint sheets for only some species (fetch-faint.sh got 60
of 251); the ROM has the authentic ground-anim set for everyone. This pulls
the three sprite bins (monster / m_ground / m_attack), merges them into the
full 44-group WAN like SpriteBot does, exports sheets via skytemple's
chara_wan, and copies JUST the Faint sheet + its AnimData <Anim> entry into
animations/<id>/ (CopyOf resolved to the sheet that owns the pixels).

  .venv/bin/python extract_faint.py 3          # Venusaur
  .venv/bin/python extract_faint.py 3 6 9 ...  # several
"""
from __future__ import annotations

import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET

from ndspy.rom import NintendoDSRom
from PIL import Image
from skytemple_files.common.types.file_types import FileType
from skytemple_files.common.util import get_ppmdu_config_for_rom
from skytemple_files.graphics.chara_wan.handler import CharaWanHandler
from skytemple_files.graphics.chara_wan.sheets import ExportSheets
from skytemple_files.graphics.chara_wan.split_merge import MergeWan
import skytemple_files.graphics.chara_wan as chara_wan_pkg

HERE = os.path.dirname(os.path.abspath(__file__))
ANIM_DIR = os.path.abspath(os.path.join(HERE, "..", "animations"))
OUT = os.path.join(HERE, "out", "faint")


def wan_from(pack, idx):
    data = pack[idx]
    try:                # some entries are AT-compressed, some raw SIR0
        data = FileType.COMMON_AT.deserialize(data).decompress()
    except ValueError:
        pass
    return CharaWanHandler.deserialize(data)


def export_all_sheets(rom, config, packs, dex):
    md = FileType.MD.deserialize(rom.getFileByName("BALANCE/monster.md"))
    sprite_idx = md.entries[dex].sprite_index
    wans = [wan_from(packs[n], sprite_idx)
            for n in ("monster.bin", "m_ground.bin", "m_attack.bin")]
    merged = MergeWan(wans)
    sprite_def = config.animation_names.get(sprite_idx) or config.animation_names[0]
    name_map = []
    for i in range(max(sprite_def.indices) + 1):
        idx = sprite_def.indices.get(i)
        name_map.append(idx.names if idx else [""])
    out_dir = os.path.join(OUT, f"{dex:03d}")
    shutil.rmtree(out_dir, ignore_errors=True)
    shadow = Image.open(os.path.join(os.path.dirname(chara_wan_pkg.__file__), "Shadow.png"))
    ExportSheets(out_dir, shadow, merged, name_map)
    return out_dir


def faint_block(exported_xml):
    """The Faint <Anim> element + the name of the sheet holding its pixels."""
    tree = ET.parse(exported_xml)
    anims = {a.findtext("Name"): a for a in tree.getroot().iter("Anim")}
    if "Faint" not in anims:
        return None, None
    sheet, seen = "Faint", set()
    while (c := anims[sheet].findtext("CopyOf")) and sheet not in seen:
        seen.add(sheet)
        sheet = c
    return anims["Faint"], sheet


def merge_into(dex, exported_dir):
    dest = os.path.join(ANIM_DIR, f"{dex:03d}")
    if not os.path.isdir(dest):
        print(f"  {dex:03d}: no animations/ folder, skipped")
        return False
    anim_el, sheet = faint_block(os.path.join(exported_dir, "AnimData.xml"))
    if anim_el is None:
        print(f"  {dex:03d}: ROM has no Faint group, skipped")
        return False
    src_png = os.path.join(exported_dir, f"{sheet}-Anim.png")
    if not os.path.isfile(src_png):
        print(f"  {dex:03d}: exported sheet {sheet}-Anim.png missing, skipped")
        return False
    shutil.copy2(src_png, os.path.join(dest, "Faint-Anim.png"))

    # Patch the species' AnimData.xml: replace/insert a plain Faint entry
    # (the sheet is saved under Faint-Anim.png, so no CopyOf indirection —
    # frame sizes come from the CopyOf target when the ROM aliased it).
    src_size = anim_el if anim_el.findtext("FrameWidth") else None
    if src_size is None:
        tree = ET.parse(os.path.join(exported_dir, "AnimData.xml"))
        src_size = next(a for a in tree.getroot().iter("Anim") if a.findtext("Name") == sheet)
    fw, fh = src_size.findtext("FrameWidth"), src_size.findtext("FrameHeight")
    durations = "".join(f"<Duration>{d.text}</Duration>"
                        for d in src_size.iter("Duration"))
    entry = ("\t\t<Anim>\n"
             f"\t\t\t<Name>Faint</Name>\n\t\t\t<Index>33</Index>\n"
             f"\t\t\t<FrameWidth>{fw}</FrameWidth>\n\t\t\t<FrameHeight>{fh}</FrameHeight>\n"
             f"\t\t\t<Durations>{durations}</Durations>\n"
             "\t\t</Anim>\n")
    path = os.path.join(dest, "AnimData.xml")
    xml = open(path, encoding="utf-8").read()
    xml = re.sub(r"[ \t]*<Anim>\s*<Name>Faint</Name>.*?</Anim>\n?", "", xml, flags=re.S)
    xml = xml.replace("</Anims>", entry + "\t</Anims>")
    open(path, "w", encoding="utf-8").write(xml)
    print(f"  {dex:03d}: Faint-Anim.png ({fw}x{fh}) + AnimData entry written")
    return True


def main():
    dexes = [int(a) for a in sys.argv[1:]]
    if not dexes:
        print(__doc__)
        sys.exit(2)
    rom = NintendoDSRom.fromFile(os.path.join(HERE, "rom.nds"))
    config = get_ppmdu_config_for_rom(rom)
    packs = {n: FileType.BIN_PACK.deserialize(rom.getFileByName(f"MONSTER/{n}"))
             for n in ("monster.bin", "m_ground.bin", "m_attack.bin")}
    for dex in dexes:
        merge_into(dex, export_all_sheets(rom, config, packs, dex))


if __name__ == "__main__":
    main()
