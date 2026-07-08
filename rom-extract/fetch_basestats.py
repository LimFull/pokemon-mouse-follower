#!/usr/bin/env python3
"""
Fetch mainline base stats (HP/Atk/Def/SpA/SpD/Spe) for Gen 1-2 species from
PokeAPI and merge them into ../gamedata/species.json under "base".

Mainline stats read cleaner than the EoS growth tables (they match player
expectations, include Speed, and make the mainline damage formula work without
a fudge factor). Design D4 revised to mainline stats.
"""
from __future__ import annotations

import json
import os
import urllib.request

DEST = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "gamedata"))
KEYS = {"hp": "hp", "attack": "atk", "defense": "def",
        "special-attack": "spa", "special-defense": "spd", "speed": "spe"}


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-mouse-follower/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def main():
    path = os.path.join(DEST, "species.json")
    species = json.load(open(path, encoding="utf-8"))
    for dex in range(1, 252):
        d = get(f"https://pokeapi.co/api/v2/pokemon/{dex}/")
        base = {KEYS[s["stat"]["name"]]: s["base_stat"] for s in d["stats"] if s["stat"]["name"] in KEYS}
        species[str(dex)]["base"] = base
        if dex % 50 == 0:
            print(f"  ...{dex}/251")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(species, f, ensure_ascii=False, separators=(",", ":"))
    print(f"merged mainline base stats into species.json (e.g. #4 = {species['4']['base']})")


if __name__ == "__main__":
    main()
