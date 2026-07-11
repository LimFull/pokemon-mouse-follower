#!/usr/bin/env python3
"""
Fetch the mainline "sound" move flag and merge it into ../gamedata/moves.json
as `sound` (true only; absent = not a sound move / no mainline match).

Same CSV source and name-matching scheme as fetch_contact.py (flag 9 = sound
in PokeAPI's move_flag_map.csv). One-time collection; the app ships the
merged JSON.

Battle playback uses this to anchor cry-type visuals: a status sound move
with no projectile (Growl, Roar, ...) emanates from just in front of the
USER instead of playing on the target.
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
SOUND_FLAG_ID = 9


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
    moves_csv = csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/moves.csv")))
    ident_by_id = {row["id"]: row["identifier"] for row in moves_csv}

    flags_csv = csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/move_flag_map.csv")))
    sound_ids = {row["move_id"] for row in flags_csv
                 if int(row["move_flag_id"]) == SOUND_FLAG_ID}
    sound_by_norm = {norm(ident): (mid in sound_ids)
                     for mid, ident in ident_by_id.items()}

    path = os.path.join(DEST, "moves.json")
    moves = json.load(open(path, encoding="utf-8"))
    tagged = []
    for mv in moves.values():
        n = norm(mv["names"].get("e", ""))
        n = ALIAS.get(n, n)
        if sound_by_norm.get(n):
            mv["sound"] = True
            tagged.append(mv["names"].get("e"))
        else:
            mv.pop("sound", None)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(moves, f, ensure_ascii=False, separators=(",", ":"))
    print(f"sound flag: {len(tagged)} moves — {sorted(tagged)}")


if __name__ == "__main__":
    main()
