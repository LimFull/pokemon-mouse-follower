#!/usr/bin/env python3
"""
Build the app-facing game-data bundle for "raising mode" from the EoS extracts.

Reads rom-extract/out/{monsters,level_stats,evolutions,moves,learnsets}.json and
writes ../gamedata/{species.json, moves.json} — a compact, FACTUAL-ONLY subset
(types, base stats, per-level growth + exp curve, learnset levels, evolution
params, move power/type/pp/accuracy). No copyrighted flavor text is included.

Scope: National Dex 1–251 (Gen 1 & 2), one record per species (base-gender md
entry). Sprite id = zero-padded dex, matching animations/<id>/.
"""
from __future__ import annotations

import json
import os
import re


def clean_desc(s: str) -> str:
    """Strip EoS markup codes and the structured 'Detailed Information' block,
    leaving just the human summary sentence(s)."""
    if not s:
        return ""
    s = s.replace("[CR]", " ").replace("[BAR]", " ")
    s = re.sub(r"\[[^\]]*\]", "", s)          # [CS:E], [LS:..], [LE], ...
    s = re.sub(r'"[^"]*"', "", s)             # quoted section headers
    s = re.split(r"Detailed Info\w*|Select detail|View detail", s)[0]
    return re.sub(r"\s+", " ", s).strip()

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "out")
DEST = os.path.abspath(os.path.join(HERE, "..", "gamedata"))
GEN12_MAX = 251


def load(name):
    with open(os.path.join(OUT, name), encoding="utf-8") as f:
        return json.load(f)


def main():
    os.makedirs(DEST, exist_ok=True)
    monsters = load("monsters/monsters.json")
    evolutions = load("monsters/evolutions.json")
    level_stats = load("monsters/level_stats.json")
    learnsets = load("moves/learnsets.json")
    moves = load("moves/moves.json")

    # --- index helpers -------------------------------------------------
    # One canonical md entry per species: the base (md_index == md_index_base)
    # entry whose dex is in 1..251.
    by_dex = {}
    mdindex_to_dex = {}
    for m in monsters:
        dex = m["national_pokedex_number"]
        mdindex_to_dex[m["md_index"]] = dex
        if 1 <= dex <= GEN12_MAX and m["md_index"] == m["md_index_base"] and dex not in by_dex:
            by_dex[dex] = m

    # level stats keyed by binpack index (== md primary index == dex for gen1-2)
    ls_by_index = {e["index"]: e for e in level_stats}
    # learnset keyed by entity_id (== md index)
    ls_moves_by_entity = {l["entity_id"]: l for l in learnsets}

    # evolutions grouped by source dex
    evo_by_dex = {}
    for e in evolutions:
        fd = mdindex_to_dex.get(e["from_md_index"])
        td = mdindex_to_dex.get(e["to_md_index"])
        if fd is None or td is None:
            continue
        if not (1 <= fd <= GEN12_MAX and 1 <= td <= GEN12_MAX):
            continue  # cap: drop evolutions leaving the gen1-2 roster
        evo_by_dex.setdefault(fd, []).append({
            "to_dex": td,
            "method": e["method"],
            "param1": e["param1"],
            "requirement": e["requirement"],
        })

    # pre-evolution lookup (within gen1-2)
    pre_evo_dex = {}
    for fd, lst in evo_by_dex.items():
        for ev in lst:
            pre_evo_dex[ev["to_dex"]] = fd

    # --- build species records ----------------------------------------
    species = {}
    for dex in sorted(by_dex):
        m = by_dex[dex]
        lsm = ls_moves_by_entity.get(m["md_index"], {})
        lst = ls_by_index.get(dex, {}).get("levels", [])
        growth = {k: [] for k in ("hp", "atk", "sp_atk", "def", "sp_def")}
        curve = []
        for row in lst:
            curve.append(row["exp_required"])
            growth["hp"].append(row["hp_growth"])
            growth["atk"].append(row["atk_growth"])
            growth["sp_atk"].append(row["sp_atk_growth"])
            growth["def"].append(row["def_growth"])
            growth["sp_def"].append(row["sp_def_growth"])
        species[str(dex)] = {
            "dex": dex,
            "id": f"{dex:03d}",
            "names": m["names"],
            "type1": m["type_primary"],
            "type2": m["type_secondary"] if m["type_secondary"] not in (None, "None") else None,
            "base_stats": m["base_stats"],
            "is_base_form": dex not in pre_evo_dex,
            "pre_evo_dex": pre_evo_dex.get(dex),
            "evolutions": evo_by_dex.get(dex, []),
            "level_up_moves": lsm.get("level_up_moves", []),
            "exp_curve": curve,       # exp required to reach L1..L100
            "growth": growth,         # per-level stat deltas (cumulative + base = stat at L)
        }

    starters = sorted(d for d, s in ((d, species[d]) for d in species) if s["is_base_form"])

    with open(os.path.join(DEST, "species.json"), "w", encoding="utf-8") as f:
        json.dump(species, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote gamedata/species.json — {len(species)} species, {len(starters)} base-form starters")

    # --- moves (factual only) -----------------------------------------
    move_out = {}
    for mv in moves:
        move_out[str(mv["move_id"])] = {
            "move_id": mv["move_id"],
            "names": mv["names"],
            "type": mv["type_name"],
            "category": mv["category_name"],
            "power": mv["base_power"],
            "pp": mv["base_pp"],
            "accuracy": mv["accuracy"],
            "desc": clean_desc(mv.get("descriptions", {}).get("e", "")),
        }
    with open(os.path.join(DEST, "moves.json"), "w", encoding="utf-8") as f:
        json.dump(move_out, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote gamedata/moves.json — {len(move_out)} moves")


if __name__ == "__main__":
    main()
