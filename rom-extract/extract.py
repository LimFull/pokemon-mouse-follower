#!/usr/bin/env python3
"""
Pokémon Mystery Dungeon: Explorers of Sky ROM asset extractor.

Extracts, using skytemple-files (the library behind SkyTemple):
  1. Move data      (BALANCE/waza_p.bin)          -> out/moves/moves.json, learnsets.json
  2. Monster data   (BALANCE/monster.md)          -> out/monsters/monsters.json, evolutions.json
  3. Animation maps (overlay10 tables, "anim.bin") -> out/anim/*.json (+ raw anim.bin)
  4. Effect sprites (EFFECT/effect.bin)            -> out/effects/effect_NNNN/ PNG sheets (+ raw .bin)
  5. Game strings   (MESSAGE/*.str)                -> out/strings/*.json (move/monster names, descriptions, full dump)

Usage:
    .venv/bin/python extract.py [--rom rom.nds] [--out out] [--only moves,anim,effects,strings] [--jobs 4]

Effect rendering runs in parallel subprocesses, each capped at 2 GiB RAM and 180 s
per entry; finished entries are recorded under out/effects/_status/ so an
interrupted run resumes where it left off.

Requires a legally dumped Explorers of Sky ROM (US/EU/JP).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback

from ndspy.rom import NintendoDSRom

from skytemple_files.common.types.file_types import FileType
from skytemple_files.common.util import get_ppmdu_config_for_rom
from skytemple_files.common.ppmdu_config.data import (
    GAME_REGION_US,
    GAME_REGION_EU,
    GAME_REGION_JP,
)
from skytemple_files.data.anim.handler import AnimHandler
from skytemple_files.data.anim.model import AnimType
from skytemple_files.graphics.effect_wan.handler import EffectWanHandler
from skytemple_files.graphics.effect_wan.sheets import ExportSheets as ExportEffectSheets
from skytemple_files.graphics.effect_screen.handler import ScreenEffectHandler
from skytemple_files.graphics.effect_screen.sheets import ExportSheets as ExportScreenSheets

# Offset of the animation tables inside overlay10 (see SkyTemple's ExtractAnimData patch)
ANIM_TABLE_START = {
    GAME_REGION_US: 0xAFD0,
    GAME_REGION_EU: 0xAFE8,
    GAME_REGION_JP: 0xAF18,
}
ANIM_TABLE_LEN = 0x14560
ANIM_SECTION_SIZES = [52, 5600, 13512, 19600]  # trap, item, move, general (rest = special moves)

# EoS internal type ids (ppmdu docs)
TYPE_NAMES = [
    "None", "Normal", "Fire", "Water", "Grass", "Electric", "Ice", "Fighting",
    "Poison", "Ground", "Flying", "Psychic", "Bug", "Rock", "Ghost", "Dragon",
    "Dark", "Steel", "Neutral",
]

CATEGORY_NAMES = {0: "Physical", 1: "Special", 2: "Status"}


def log(msg):
    print(msg, flush=True)


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    return path


def dump_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    log(f"  wrote {path}")


# ---------------------------------------------------------------- strings

def load_string_files(rom, config):
    """Return {lang_suffix: [strings...]} for every MESSAGE/*.str in the ROM."""
    result = {}
    for name in sorted(rom.filenames["MESSAGE"].files):
        if not name.endswith(".str"):
            continue
        lang = os.path.splitext(name)[0].replace("text_", "")
        try:
            model = FileType.STR.deserialize(rom.getFileByName(f"MESSAGE/{name}"))
            result[lang] = list(model.strings)
            log(f"  loaded MESSAGE/{name}: {len(model.strings)} strings")
        except Exception as e:
            log(f"  ! failed to decode MESSAGE/{name}: {e}")
    return result


def find_block(config, *keywords):
    """Find the string block whose name contains all keywords (case-insensitive).
    Prefers the shortest matching name ('Pokemon Names' over 'Dungeon Pokemon Stat Names')."""
    blocks = config.string_index_data.string_blocks
    matches = [
        (name, blk)
        for name, blk in blocks.items()
        if all(k.lower() in name.lower() for k in keywords)
    ]
    if not matches:
        return None, None
    return min(matches, key=lambda nb: len(nb[0]))


def slice_block(strings, blk):
    return strings[blk.begin : blk.end]


def extract_strings(rom, config, out_dir, strings_by_lang):
    out = ensure_dir(os.path.join(out_dir, "strings"))
    # Full dumps (indexes match message_id references elsewhere)
    for lang, strings in strings_by_lang.items():
        dump_json(os.path.join(out, f"all_strings_{lang}.json"), strings)

    # Convenience: named blocks
    blocks_info = {}
    for label, keywords in {
        "move_names": ("move", "names"),
        "move_descriptions": ("move", "descript"),
        "monster_names": ("pokemon", "names"),
        "item_names": ("item", "names"),
        "type_names": ("type", "names"),
    }.items():
        name, blk = find_block(config, *keywords)
        if blk is None:
            log(f"  ! string block not found for {label}")
            continue
        blocks_info[label] = {"block": name, "begin": blk.begin, "end": blk.end}
        per_lang = {lang: slice_block(s, blk) for lang, s in strings_by_lang.items()}
        dump_json(os.path.join(out, f"{label}.json"), per_lang)
    dump_json(os.path.join(out, "blocks_index.json"), blocks_info)


# ---------------------------------------------------------------- moves

def serialize_range_settings(rs):
    return {
        "target": int(rs.target),
        "range": int(rs.range),
        "condition": int(rs.condition),
        "unused": int(rs.unused),
    }


def extract_moves(rom, config, out_dir, strings_by_lang):
    out = ensure_dir(os.path.join(out_dir, "moves"))
    waza = FileType.WAZA_P.deserialize(rom.getFileByName("BALANCE/waza_p.bin"))

    name_blk = find_block(config, "move", "names")[1]
    desc_blk = find_block(config, "move", "descript")[1]

    moves = []
    for i, m in enumerate(waza.moves):
        entry = {
            "move_id": int(m.move_id),
            "index": i,
            "names": {},
            "descriptions": {},
            "base_power": int(m.base_power),
            "type_id": int(m.type),
            "type_name": TYPE_NAMES[m.type] if m.type < len(TYPE_NAMES) else None,
            "category_id": int(m.category),
            "category_name": CATEGORY_NAMES.get(int(m.category)),
            "base_pp": int(m.base_pp),
            "accuracy": int(m.accuracy),
            "miss_accuracy": int(m.miss_accuracy),
            "ai_weight": int(m.ai_weight),
            "ai_condition1_chance": int(m.ai_condition1_chance),
            "number_chained_hits": int(m.number_chained_hits),
            "max_upgrade_level": int(m.max_upgrade_level),
            "crit_chance": int(m.crit_chance),
            "affected_by_magic_coat": bool(m.affected_by_magic_coat),
            "is_snatchable": bool(m.is_snatchable),
            "uses_mouth": bool(m.uses_mouth),
            "ignores_taunted": bool(m.ignores_taunted),
            "range_check_text": int(m.range_check_text),
            "message_id": int(m.message_id),
            "settings_range": serialize_range_settings(m.settings_range),
            "settings_range_ai": serialize_range_settings(m.settings_range_ai),
        }
        for lang, strings in strings_by_lang.items():
            if name_blk and name_blk.begin + i < name_blk.end:
                entry["names"][lang] = strings[name_blk.begin + i]
            if desc_blk and desc_blk.begin + i < desc_blk.end:
                entry["descriptions"][lang] = strings[desc_blk.begin + i]
        moves.append(entry)
    dump_json(os.path.join(out, "moves.json"), moves)

    monster_blk = find_block(config, "pokemon", "names")[1]
    learnsets = []
    for i, ls in enumerate(waza.learnsets):
        names = {}
        if monster_blk and monster_blk.begin + i < monster_blk.end:
            names = {lang: s[monster_blk.begin + i] for lang, s in strings_by_lang.items()}
        learnsets.append(
            {
                "entity_id": i,
                "names": names,
                "level_up_moves": [
                    {"level": int(lm.level_id), "move_id": int(lm.move_id)} for lm in ls.level_up_moves
                ],
                "tm_hm_moves": [int(x) for x in ls.tm_hm_moves],
                "egg_moves": [int(x) for x in ls.egg_moves],
            }
        )
    dump_json(os.path.join(out, "learnsets.json"), learnsets)
    return waza


# ---------------------------------------------------------------- monsters / evolution

def extract_monsters(rom, config, out_dir, strings_by_lang):
    """Per-monster evolution data from BALANCE/monster.md.

    The evolution requirement is stored on the *evolved* entry: its
    ``pre_evo_index`` points back to the pre-evolution, and ``evo_method`` /
    ``evo_param1`` / ``evo_param2`` describe how to reach it.
      method LEVEL -> param1 = level, ITEMS -> param1 = item id, IQ -> param1 = IQ,
      param2 = an extra requirement (link cable, gender, ribbon, stat compare, ...).
    """
    from skytemple_files.data.md.protocol import EvolutionMethod, AdditionalRequirement

    out = ensure_dir(os.path.join(out_dir, "monsters"))
    md = FileType.MD.deserialize(rom.getFileByName("BALANCE/monster.md"))
    name_blk = find_block(config, "pokemon", "names")[1]

    # Every species has two md entries (♂/♀); the secondary one sits past the name
    # table, so resolve names through md_index_base (the primary/base entry index).
    base_of = {i: int(e.md_index_base) for i, e in enumerate(md.entries)}

    def name_of(idx):
        idx = base_of.get(idx, idx)
        if name_blk and 0 <= idx and name_blk.begin + idx < name_blk.end:
            return {lang: s[name_blk.begin + idx] for lang, s in strings_by_lang.items()}
        return {}

    def enum_name(enum, v):
        try:
            return enum(int(v)).name
        except Exception:
            return None

    monsters, evolutions, seen = [], [], set()
    for i, e in enumerate(md.entries):
        method_id = int(e.evo_method)
        tp = int(e.type_primary)
        ts = int(e.type_secondary)
        monsters.append({
            "md_index": i,
            "md_index_base": int(e.md_index_base),
            "entid": int(e.entid),
            "national_pokedex_number": int(e.national_pokedex_number),
            "gender": int(e.gender),
            "names": name_of(i),
            "type_primary_id": tp,
            "type_primary": TYPE_NAMES[tp] if tp < len(TYPE_NAMES) else None,
            "type_secondary_id": ts,
            "type_secondary": TYPE_NAMES[ts] if ts < len(TYPE_NAMES) else None,
            "base_stats": {
                "hp": int(e.base_hp), "atk": int(e.base_atk), "def": int(e.base_def),
                "sp_atk": int(e.base_sp_atk), "sp_def": int(e.base_sp_def),
            },
            "ability_primary_id": int(e.ability_primary),
            "ability_secondary_id": int(e.ability_secondary),
            "iq_group": int(e.iq_group),
            "can_evolve": bool(e.can_evolve),
            "pre_evo_index": int(e.pre_evo_index),
            "evo_method_id": method_id,
            "evo_method": enum_name(EvolutionMethod, method_id),
            "evo_param1": int(e.evo_param1),
            "evo_requirement_id": int(e.evo_param2),
            "evo_requirement": enum_name(AdditionalRequirement, e.evo_param2),
        })
        if e.pre_evo_index != 0 and method_id != 0:
            # Collapse the ♂/♀ duplicate entries into one edge per distinct evolution.
            key = (base_of.get(int(e.pre_evo_index)), int(e.md_index_base),
                   method_id, int(e.evo_param1), int(e.evo_param2))
            if key in seen:
                continue
            seen.add(key)
            evolutions.append({
                "from_md_index": int(e.pre_evo_index),
                "from_name": name_of(int(e.pre_evo_index)),
                "to_md_index": i,
                "to_entid": int(e.entid),
                "to_national_pokedex_number": int(e.national_pokedex_number),
                "to_name": name_of(i),
                "method_id": method_id,
                "method": enum_name(EvolutionMethod, method_id),
                "param1": int(e.evo_param1),   # level / item id / IQ, per method
                "requirement_id": int(e.evo_param2),
                "requirement": enum_name(AdditionalRequirement, e.evo_param2),
            })
    dump_json(os.path.join(out, "monsters.json"), monsters)
    dump_json(os.path.join(out, "evolutions.json"), evolutions)


def extract_level_stats(rom, config, out_dir, strings_by_lang):
    """Per-monster, per-level stat tables from BALANCE/m_level.bin.

    Each entry is SIR0-wrapped, PKDPX-compressed. A level row holds the EXP
    required and the *growth* added at that level (hp/atk/sp_atk/def/sp_def);
    the game sums the growths, so we also emit the cumulative stat per level.
    """
    from skytemple_files.container.sir0.handler import Sir0Handler
    from skytemple_files.data.level_bin_entry.handler import LevelBinEntryHandler

    out = ensure_dir(os.path.join(out_dir, "monsters"))
    binpack = FileType.BIN_PACK.deserialize(rom.getFileByName("BALANCE/m_level.bin"))
    name_blk = find_block(config, "pokemon", "names")[1]

    def name_of(idx):
        if name_blk and 0 <= idx and name_blk.begin + idx < name_blk.end:
            return {lang: s[name_blk.begin + idx] for lang, s in strings_by_lang.items()}
        return {}

    result = []
    for i in range(len(binpack)):
        try:
            sir0 = Sir0Handler.deserialize(binpack[i])
            dec = FileType.PKDPX.deserialize(sir0.content).decompress()
            lbe = LevelBinEntryHandler.deserialize(dec)
        except Exception:
            continue
        hp = atk = spatk = dfn = spdef = 0
        levels = []
        for lv, x in enumerate(lbe.levels, start=1):
            hp += int(x.hp_growth); atk += int(x.attack_growth)
            spatk += int(x.special_attack_growth); dfn += int(x.defense_growth)
            spdef += int(x.special_defense_growth)
            levels.append({
                "level": lv,
                "exp_required": int(x.experience_required),
                "hp_growth": int(x.hp_growth),
                "atk_growth": int(x.attack_growth),
                "sp_atk_growth": int(x.special_attack_growth),
                "def_growth": int(x.defense_growth),
                "sp_def_growth": int(x.special_defense_growth),
                "hp": hp, "attack": atk, "sp_attack": spatk,
                "defense": dfn, "sp_defense": spdef,
            })
        result.append({"index": i, "names": name_of(i), "levels": levels})
    dump_json(os.path.join(out, "level_stats.json"), result)


# ---------------------------------------------------------------- animation tables

def build_anim_bin(rom, config):
    """Reconstruct anim.bin from overlay10, exactly like SkyTemple's ExtractAnimData patch."""
    if "BALANCE/anim.bin" in rom.filenames:
        log("  found BALANCE/anim.bin in ROM (ExtractAnimData patch applied), using it")
        return rom.getFileByName("BALANCE/anim.bin")
    start = ANIM_TABLE_START[config.game_region]
    ov10 = rom.loadArm9Overlays([10])[10].data
    header = bytearray()
    offset = 5 * 4
    header += offset.to_bytes(4, "little")
    for size in ANIM_SECTION_SIZES:
        offset += size
        header += offset.to_bytes(4, "little")
    return bytes(header) + bytes(ov10[start : start + ANIM_TABLE_LEN])


def extract_anim(rom, config, out_dir, strings_by_lang):
    out = ensure_dir(os.path.join(out_dir, "anim"))
    raw = build_anim_bin(rom, config)
    with open(os.path.join(out, "anim.bin"), "wb") as f:
        f.write(raw)
    anim = AnimHandler.deserialize(raw)

    move_name_blk = find_block(config, "move", "names")[1]
    first_lang = next(iter(strings_by_lang), None)

    def move_name(i):
        if move_name_blk and first_lang and move_name_blk.begin + i < move_name_blk.end:
            return strings_by_lang[first_lang][move_name_blk.begin + i]
        return None

    dump_json(
        os.path.join(out, "move_animations.json"),
        [
            {
                "move_id": i,
                "move_name": move_name(i),
                "anim1": int(a.anim1),
                "anim2": int(a.anim2),
                "anim3": int(a.anim3),
                "anim4": int(a.anim4),
                "dir": int(a.dir),
                "flag1": a.flag1,
                "flag2": a.flag2,
                "flag3": a.flag3,
                "flag4": a.flag4,
                "speed": int(a.speed),
                "animation": int(a.animation),
                "point": a.point.name,
                "sfx": int(a.sfx),
                "spec_entries": int(a.spec_entries),
                "spec_start": int(a.spec_start),
            }
            for i, a in enumerate(anim.move_table)
        ],
    )
    dump_json(
        os.path.join(out, "general_animations.json"),
        [
            {
                "anim_id": i,
                "anim_type": a.anim_type.name,
                "anim_file": int(a.anim_file),  # index into EFFECT/effect.bin
                "sfx": int(a.sfx),
                "point": a.point.name,
                "loop": a.loop,
                "unk1": int(a.unk1),
                "unk2": int(a.unk2),
                "unk3": int(a.unk3),
                "unk4": a.unk4,
                "unk5": a.unk5,
            }
            for i, a in enumerate(anim.general_table)
        ],
    )
    dump_json(
        os.path.join(out, "trap_animations.json"),
        [{"trap_id": i, "anim": int(a.anim)} for i, a in enumerate(anim.trap_table)],
    )
    dump_json(
        os.path.join(out, "item_animations.json"),
        [{"item_id": i, "anim1": int(a.anim1), "anim2": int(a.anim2)} for i, a in enumerate(anim.item_table)],
    )
    dump_json(
        os.path.join(out, "special_move_animations.json"),
        [
            {
                "index": i,
                "pkmn_id": int(a.pkmn_id),
                "animation": int(a.animation),
                "point": a.point.name,
                "sfx": int(a.sfx),
            }
            for i, a in enumerate(anim.special_move_table)
        ],
    )
    return anim


# ---------------------------------------------------------------- effects

WORKER_MEM_LIMIT = 2 * 1024**3  # 2 GiB per worker: runaway renders fail with MemoryError
WORKER_TIMEOUT_S = 180  # per-entry alarm so a hung render can't stall the run


def _status_path(out, i):
    return os.path.join(out, "_status", f"effect_{i:04d}.json")


def _export_one_effect(job):
    """Worker: export a single effect.bin entry. Runs in a fresh subprocess."""
    import resource
    import signal

    i, data, types_used, want_screen_first, out = job

    status_file = _status_path(out, i)
    if os.path.isfile(status_file):  # already done in a previous run
        with open(status_file, encoding="utf-8") as f:
            return json.load(f)

    try:
        resource.setrlimit(resource.RLIMIT_DATA, (WORKER_MEM_LIMIT, WORKER_MEM_LIMIT))
    except (ValueError, OSError):
        pass

    def on_timeout(signum, frame):
        raise TimeoutError(f"effect {i} render timed out")

    signal.signal(signal.SIGALRM, on_timeout)
    signal.alarm(WORKER_TIMEOUT_S)

    entry_dir = os.path.join(out, f"effect_{i:04d}")
    with open(os.path.join(out, f"effect_{i:04d}.bin"), "wb") as f:
        f.write(data)
    info = {"index": i, "size": len(data), "used_as": types_used, "exported": "raw_only"}
    attempts = ["screen", "wan"] if want_screen_first else ["wan", "screen"]
    for kind in attempts:
        try:
            if kind == "wan":
                wan = EffectWanHandler.deserialize(data)
                ExportEffectSheets(entry_dir, wan)
            else:
                screen = ScreenEffectHandler.deserialize(data)
                ExportScreenSheets(entry_dir, screen, True)
            info["exported"] = kind
            break
        except (Exception, MemoryError, TimeoutError) as e:
            info["error"] = f"{kind}: {type(e).__name__}"
            continue

    signal.alarm(0)
    with open(status_file, "w", encoding="utf-8") as f:
        json.dump(info, f)
    return info


def extract_effects(rom, config, out_dir, anim, jobs):
    from concurrent.futures import ProcessPoolExecutor, as_completed
    from concurrent.futures.process import BrokenProcessPool

    out = ensure_dir(os.path.join(out_dir, "effects"))
    ensure_dir(os.path.join(out, "_status"))
    bin_pack = FileType.BIN_PACK.deserialize(rom.getFileByName("EFFECT/effect.bin"))
    log(f"  EFFECT/effect.bin contains {len(bin_pack)} files")

    # Which effect file indices are used with which AnimType (from the general table)?
    usage = {}
    if anim is not None:
        for a in anim.general_table:
            usage.setdefault(int(a.anim_file), set()).add(a.anim_type)

    work = []
    for i, data in enumerate(bin_pack):
        types = usage.get(i, set())
        work.append(
            (
                i,
                bytes(data),
                sorted(t.name for t in types),
                bool(types) and types <= {AnimType.SCREEN, AnimType.WBA},
                out,
            )
        )

    done = sum(1 for w in work if os.path.isfile(_status_path(out, w[0])))
    if done:
        log(f"  resuming: {done}/{len(work)} entries already finished")

    log(f"  rendering with {jobs} parallel workers (2 GiB / {WORKER_TIMEOUT_S}s per entry)...")
    index = []
    # max_tasks_per_child=1: fresh process per entry, no memory accumulation
    with ProcessPoolExecutor(max_workers=jobs, max_tasks_per_child=1) as pool:
        futures = {pool.submit(_export_one_effect, w): w[0] for w in work}
        for n, fut in enumerate(as_completed(futures), 1):
            i = futures[fut]
            try:
                index.append(fut.result())
            except (BrokenProcessPool, Exception) as e:
                log(f"  ! effect {i} worker died: {type(e).__name__}")
                index.append({"index": i, "exported": "failed", "error": type(e).__name__})
            if n % 25 == 0 or n == len(work):
                log(f"  effect {n}/{len(work)} done")
    index.sort(key=lambda e: e["index"])

    dump_json(os.path.join(out, "effects_index.json"), index)
    ok = sum(1 for e in index if e["exported"] in ("wan", "screen"))
    log(f"  exported sheets for {ok}/{len(index)} effect files (rest saved raw)")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rom", default=os.path.join(os.path.dirname(__file__), "rom.nds"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    ap.add_argument("--only", default="strings,moves,monsters,anim,effects", help="comma-separated sections")
    ap.add_argument("--jobs", type=int, default=4, help="parallel effect-render workers")
    args = ap.parse_args()

    if not os.path.isfile(args.rom):
        sys.exit(
            f"ROM not found: {args.rom}\n"
            "Place your legally dumped 'Pokémon Mystery Dungeon: Explorers of Sky' ROM there,\n"
            "or pass --rom /path/to/rom.nds"
        )

    rom = NintendoDSRom.fromFile(args.rom)
    config = get_ppmdu_config_for_rom(rom)
    log(f"ROM loaded: {config.game_version} / region {config.game_region}")
    ensure_dir(args.out)

    sections = [s.strip() for s in args.only.split(",") if s.strip()]
    strings_by_lang = load_string_files(rom, config)

    anim = None
    if "strings" in sections:
        log("== strings ==")
        extract_strings(rom, config, args.out, strings_by_lang)
    if "moves" in sections:
        log("== moves ==")
        extract_moves(rom, config, args.out, strings_by_lang)
    if "monsters" in sections:
        log("== monsters / evolution ==")
        extract_monsters(rom, config, args.out, strings_by_lang)
        log("== level-up stats ==")
        extract_level_stats(rom, config, args.out, strings_by_lang)
    if "anim" in sections:
        log("== animation tables ==")
        anim = extract_anim(rom, config, args.out, strings_by_lang)
    if "effects" in sections:
        log("== effect sprites ==")
        if anim is None:
            try:
                anim = AnimHandler.deserialize(build_anim_bin(rom, config))
            except Exception:
                traceback.print_exc()
        extract_effects(rom, config, args.out, anim, args.jobs)

    dump_json(
        os.path.join(args.out, "meta.json"),
        {
            "game_version": config.game_version,
            "game_region": config.game_region,
            "languages": sorted(strings_by_lang.keys()),
            "sections": sections,
        },
    )
    log("Done.")


if __name__ == "__main__":
    main()
