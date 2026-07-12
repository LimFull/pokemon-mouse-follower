#!/usr/bin/env python3
"""
Fetch mainline move accuracy and merge it into ../gamedata/moves.json as
`accuracy_main` (0 = the mainline move never misses; absent = no mainline
match, keep the EoS value).

Same CSV source and name-matching scheme as fetch_contact.py. One-time
collection; the app ships the merged JSON.

The battle engine rolls with accuracy_main when present: EoS's dungeon
balance runs far lower (Fury Attack 55 vs mainline 85), which made desktop
battles whiff constantly.
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
    rows = list(csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/moves.csv"))))
    acc_by_norm = {}
    for row in rows:
        acc = row["accuracy"]
        acc_by_norm[norm(row["identifier"])] = int(acc) if acc else 0   # 0 = never misses

    path = os.path.join(DEST, "moves.json")
    moves = json.load(open(path, encoding="utf-8"))
    merged = changed = 0
    for mv in moves.values():
        n = norm(mv["names"].get("e", ""))
        n = ALIAS.get(n, n)
        if n in acc_by_norm:
            mv["accuracy_main"] = acc_by_norm[n]
            merged += 1
            changed += mv["accuracy_main"] != mv.get("accuracy")
        else:
            mv.pop("accuracy_main", None)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(moves, f, ensure_ascii=False, separators=(",", ":"))
    print(f"accuracy_main merged for {merged} moves ({changed} differ from the EoS value)")


if __name__ == "__main__":
    main()
