#!/usr/bin/env python3
"""
Fetch the mainline "makes contact" flag and merge it into ../gamedata/moves.json
as `contact` (true/false; absent = no mainline match).

The REST API doesn't expose move flags, so this reads PokeAPI's source CSVs:
  moves.csv          — mainline move id -> identifier ("thunder-shock")
  move_flag_map.csv  — move id -> flag id (flag 1 = contact)

Matched by normalized English name (EoS -> mainline), same scheme and aliases
as fetch_supplement.py. One-time collection; the app ships the merged JSON.

Battle playback uses this to decide lunge-vs-ranged delivery: contact moves
ram the foe, everything else is cast from range (BattleController.rangedVisual).
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
CONTACT_FLAG_ID = 1


def get_text(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-mouse-follower/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8")


def norm(name: str) -> str:
    """'Iron Tail' / 'DoubleSlap' / 'double-slap' -> 'doubleslap' etc."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


ALIAS = {
    "faintattack": "feintattack",   # renamed Feint Attack in later gens
    "hijumpkick": "highjumpkick",
    "smellingsalt": "smellingsalts",
}


def main():
    moves_csv = csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/moves.csv")))
    ident_by_id = {row["id"]: row["identifier"] for row in moves_csv}

    flags_csv = csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/move_flag_map.csv")))
    contact_ids = {row["move_id"] for row in flags_csv
                   if int(row["move_flag_id"]) == CONTACT_FLAG_ID}
    contact_by_norm = {norm(ident): (mid in contact_ids)
                       for mid, ident in ident_by_id.items()}

    path = os.path.join(DEST, "moves.json")
    moves = json.load(open(path, encoding="utf-8"))
    merged = contact = 0
    unmatched = []
    for mv in moves.values():
        n = norm(mv["names"].get("e", ""))
        n = ALIAS.get(n, n)
        if n in contact_by_norm:
            mv["contact"] = contact_by_norm[n]
            merged += 1
            contact += contact_by_norm[n]
        elif mv["names"].get("e") not in ("Nothing", "-"):
            unmatched.append(mv["names"].get("e"))

    with open(path, "w", encoding="utf-8") as f:
        json.dump(moves, f, ensure_ascii=False, separators=(",", ":"))
    print(f"merged contact flag: {merged} moves ({contact} contact), "
          f"{len(unmatched)} unmatched: {unmatched}")


if __name__ == "__main__":
    main()
