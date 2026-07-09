#!/usr/bin/env python3
"""
Fetch the mainline supplement dataset (design 2.2-H) from PokeAPI and merge it
into ../gamedata/{species.json, moves.json}:

  species (dex 1-251):
    base_exp     — base experience yield (D6-1 EXP formula)
    capture_rate — mainline catch rate (D11, Phase 3)
    gender_rate  — female eighths, -1 = genderless (G / D17)

  moves (matched by normalized English name, EoS -> mainline):
    ailment        — status condition the move can inflict (D19/D19-1),
                     only stored when not "none"
    ailment_chance — % chance; 0 on a status-category move means "always"

One-time collection; the app ships the merged JSON and stays offline.
"""
from __future__ import annotations

import json
import os
import re
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DEST = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "gamedata"))


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-mouse-follower/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def norm(name: str) -> str:
    """'Iron Tail' / 'DoubleSlap' / 'double-slap' -> 'doubleslap' etc."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def fetch_species():
    path = os.path.join(DEST, "species.json")
    species = json.load(open(path, encoding="utf-8"))

    def one(dex):
        p = get(f"https://pokeapi.co/api/v2/pokemon/{dex}/")
        s = get(f"https://pokeapi.co/api/v2/pokemon-species/{dex}/")
        return dex, p["base_experience"], s["capture_rate"], s["gender_rate"]

    with ThreadPoolExecutor(max_workers=8) as ex:
        for dex, bexp, crate, grate in ex.map(one, range(1, 252)):
            rec = species[str(dex)]
            rec["base_exp"] = bexp
            rec["capture_rate"] = crate
            rec["gender_rate"] = grate
            if dex % 50 == 0:
                print(f"  species ...{dex}/251")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(species, f, ensure_ascii=False, separators=(",", ":"))
    print(f"merged species supplement (e.g. #1 = base_exp {species['1']['base_exp']}, "
          f"capture {species['1']['capture_rate']}, gender_rate {species['1']['gender_rate']})")


def fetch_moves():
    path = os.path.join(DEST, "moves.json")
    moves = json.load(open(path, encoding="utf-8"))

    index = get("https://pokeapi.co/api/v2/move?limit=2000")["results"]
    by_norm = {norm(m["name"]): m["url"] for m in index}

    # A few EoS names differ beyond punctuation from mainline names.
    ALIAS = {
        "faintattack": "feintattack",   # renamed Feint Attack in later gens
        "hijumpkick": "highjumpkick",
        "smellingsalt": "smellingsalts",
    }

    targets = []
    unmatched = []
    for key, mv in moves.items():
        n = norm(mv["names"].get("e", ""))
        n = ALIAS.get(n, n)
        url = by_norm.get(n)
        if url:
            targets.append((key, url))
        elif mv["names"].get("e") not in ("Nothing", "-"):
            unmatched.append(mv["names"].get("e"))

    def one(item):
        key, url = item
        d = get(url)
        meta = d.get("meta") or {}
        ail = (meta.get("ailment") or {}).get("name", "none")
        return key, ail, meta.get("ailment_chance", 0), d.get("power")

    done = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        for key, ail, chance, power in ex.map(one, targets):
            if ail and ail != "none":
                moves[key]["ailment"] = ail
                moves[key]["ailment_chance"] = chance
            if power:                      # mainline base power (null = status/variable)
                moves[key]["power_main"] = power
            done += 1
            if done % 100 == 0:
                print(f"  moves ...{done}/{len(targets)}")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(moves, f, ensure_ascii=False, separators=(",", ":"))
    with_ail = sum(1 for m in moves.values() if m.get("ailment"))
    print(f"merged move ailments: {with_ail} moves with an ailment, "
          f"{len(unmatched)} unmatched: {unmatched}")


if __name__ == "__main__":
    fetch_species()
    fetch_moves()
