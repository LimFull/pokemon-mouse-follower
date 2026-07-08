#!/usr/bin/env python3
"""
Fetch the mainline type-effectiveness chart from PokeAPI (public, canonical —
design D5/#6) into ../gamedata/typechart.json:  {attacker: {defender: mult}}.

Only non-1.0 multipliers are stored. EoS' "Neutral" (typeless) is added as 1x
vs everything. Run once; result is bundled and used offline.
"""
from __future__ import annotations

import json
import os
import urllib.request

DEST = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "gamedata"))
TYPES = ["normal", "fire", "water", "grass", "electric", "ice", "fighting",
         "poison", "ground", "flying", "psychic", "bug", "rock", "ghost",
         "dragon", "dark", "steel", "fairy"]


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-mouse-follower/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def cap(t):
    return t.capitalize()


def main():
    chart = {}
    for t in TYPES:
        d = get(f"https://pokeapi.co/api/v2/type/{t}/")["damage_relations"]
        rel = {}
        for e in d["double_damage_to"]:
            rel[cap(e["name"])] = 2.0
        for e in d["half_damage_to"]:
            rel[cap(e["name"])] = 0.5
        for e in d["no_damage_to"]:
            rel[cap(e["name"])] = 0.0
        chart[cap(t)] = rel
        print(f"  {cap(t)}: {len(rel)} non-neutral matchups")
    chart["Neutral"] = {}   # typeless: 1x vs everything
    os.makedirs(DEST, exist_ok=True)
    with open(os.path.join(DEST, "typechart.json"), "w", encoding="utf-8") as f:
        json.dump(chart, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote gamedata/typechart.json — {len(chart)} attacking types")


if __name__ == "__main__":
    main()
