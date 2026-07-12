#!/usr/bin/env python3
"""
Fetch mainline secondary effects for DAMAGING moves and merge them into
../gamedata/moves.json:

  sec_stats  {"spd": -1, ...}   stat stages the secondary shifts
  sec_chance 10                 % chance (0 in the CSV = always -> stored 100)
  sec_self   true               the stats hit the USER (Overheat, Superpower)

Source: PokeAPI move_meta.csv (+ move_meta_stat_changes.csv); category 6 =
damage+lower (target), 7 = damage+raise (user). Same name matching as
fetch_contact.py. One-time collection; the app ships the merged JSON.

The battle engine applies these generically after a landed hit, so Psychic's
SpDef drop, Metal Claw's Atk boost, and Overheat's self -2 all work without
per-move Swift cases.
"""
from __future__ import annotations

import csv
import io
import json
import os
import re
import urllib.request

DEST = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "gamedata"))
CSV_BASE = "https://raw.githubusercontent.com/PokeAPI/pokeapi/master/data/v2/csv"
STAT_NAMES = {"2": "atk", "3": "def", "4": "spa", "5": "spd",
              "6": "spe", "7": "acc", "8": "eva"}


def get_text(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-mouse-follower/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8")


def norm(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


ALIAS = {
    "faintattack": "feintattack",
    "hijumpkick": "highjumpkick",
    "smellingsalt": "smellingsalts",
}


def main():
    ident = {r["id"]: r["identifier"]
             for r in csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/moves.csv")))}
    meta = {r["move_id"]: r
            for r in csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/move_meta.csv")))}
    changes: dict[str, dict[str, int]] = {}
    for r in csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/move_meta_stat_changes.csv"))):
        name = STAT_NAMES.get(r["stat_id"])
        if name:
            changes.setdefault(r["move_id"], {})[name] = int(r["change"])
    by_norm = {norm(i): mid for mid, i in ident.items()}

    path = os.path.join(DEST, "moves.json")
    moves = json.load(open(path, encoding="utf-8"))
    merged = 0
    for mv in moves.values():
        for key in ("sec_stats", "sec_chance", "sec_self"):
            mv.pop(key, None)
        if mv.get("category") == "Status":
            continue   # pure stat moves are the mechanics table's job
        n = ALIAS.get(norm(mv["names"].get("e", "")), norm(mv["names"].get("e", "")))
        mid = by_norm.get(n)
        if not mid or mid not in meta or mid not in changes:
            continue
        cat = meta[mid]["meta_category_id"]
        if cat not in ("6", "7"):
            continue
        chance = int(meta[mid]["stat_chance"] or 0)
        mv["sec_stats"] = changes[mid]
        mv["sec_chance"] = 100 if chance == 0 else chance
        if cat == "7":
            mv["sec_self"] = True
        merged += 1
    with open(path, "w", encoding="utf-8") as f:
        json.dump(moves, f, ensure_ascii=False, separators=(",", ":"))
    print(f"secondary stat changes merged for {merged} moves")


if __name__ == "__main__":
    main()
