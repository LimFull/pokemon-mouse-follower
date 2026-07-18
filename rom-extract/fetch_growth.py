#!/usr/bin/env python3
"""
Replace each species' exp_curve in ../gamedata/species.json with the MAINLINE
growth curve (design D6-1 follow-up, 2026-07-18).

The original exp_curve came from the EoS ROM's per-level exp_required table —
a PMD-native pacing (Bulbasaur L100 = 2,547,402) that is ~2.4x steeper than
mainline (medium-slow L100 = 1,059,860). Battle EXP payouts use the mainline
formula (base_exp x level / 7, fetch_supplement.py), so leveling only feels
mainline if the requirement curve is mainline too.

Source: PokeAPI growth-rate tables (exact per-level totals, so no formula
edge cases like medium-slow's negative L1) + each species' growth_rate name.
The array keeps the same shape (total EXP to reach L1..L100, L1 = 0), so the
app code needs no change. Also records `growth_rate` per species for reference.

One-time collection; the app ships the merged JSON and stays offline.
"""
from __future__ import annotations

import json
import os
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DEST = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "gamedata"))


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-mouse-follower/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main():
    path = os.path.join(DEST, "species.json")
    species = json.load(open(path, encoding="utf-8"))

    def one(dex):
        s = get(f"https://pokeapi.co/api/v2/pokemon-species/{dex}/")
        return dex, s["growth_rate"]["name"]

    with ThreadPoolExecutor(max_workers=8) as ex:
        rates = dict(ex.map(one, range(1, 252)))
    print(f"growth rates: { {r: sum(1 for v in rates.values() if v == r) for r in set(rates.values())} }")

    curves: dict[str, list[int]] = {}
    for name in sorted(set(rates.values())):
        levels = get(f"https://pokeapi.co/api/v2/growth-rate/{name}/")["levels"]
        by_level = {e["level"]: e["experience"] for e in levels}
        curve = [by_level[lv] for lv in range(1, 101)]   # KeyError = API shape changed
        assert curve[0] == 0 and curve == sorted(curve), f"bad curve for {name}"
        curves[name] = curve
        print(f"  {name}: L100 = {curve[99]:,}")

    for dex in range(1, 252):
        rec = species[str(dex)]
        rec["exp_curve"] = curves[rates[dex]]
        rec["growth_rate"] = rates[dex]

    with open(path, "w", encoding="utf-8") as f:
        json.dump(species, f, ensure_ascii=False, separators=(",", ":"))
    print(f"merged mainline exp curves (e.g. #1 {rates[1]}: "
          f"L100 = {species['1']['exp_curve'][99]:,})")


if __name__ == "__main__":
    main()
