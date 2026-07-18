#!/usr/bin/env python3
"""
Pin the mainline move stats in ../gamedata/moves.json (power_main /
accuracy_main) to their GENERATION 5 values via PokeAPI past_values.

Why gen 5 (user decision, 2026-07-18): the app's learnsets come from EoS
(gen-4-era games), and gen 6 buffed many weak early moves up to their
successors' stats — Bubble 20->40 made Squirtle's Bubble -> Water Gun
progression meaningless (both 40/100; user report). Gen 5 restores the
classic power identities (Bubble 20, Thunderbolt 95, Thunder 120, ...)
while keeping gen 5's accuracy cleanups over gen 4's (Bind 75% & co).

PokeAPI semantics: past_values[{version_group, power, accuracy, ...}] =
the values a move had BEFORE that version group. Value at gen G = the
non-null field from the entry with the smallest version-group generation
> G, else the current value.

Curated fields are preserved:
  - accuracy_main == 0 means "never misses" (Swift, Roar, ...) — kept.
  - Hidden Power keeps the fixed 60 (its old per-IV 1..70 isn't modeled).

One-time collection; the app ships the merged JSON and stays offline.
"""
from __future__ import annotations

import json
import os
import re
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DEST = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "gamedata"))
PIN_GEN = 5
SKIP = {"Hidden Power"}


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-mouse-follower/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def norm(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


def main():
    path = os.path.join(DEST, "moves.json")
    moves = json.load(open(path, encoding="utf-8"))

    vgs = get("https://pokeapi.co/api/v2/version-group?limit=40")["results"]

    def gen_of(url):
        return int(get(url)["generation"]["url"].rstrip("/").rsplit("/", 1)[1])

    with ThreadPoolExecutor(max_workers=8) as ex:
        vggen = dict(zip([v["name"] for v in vgs],
                         ex.map(gen_of, [v["url"] for v in vgs])))

    index = get("https://pokeapi.co/api/v2/move?limit=2000")["results"]
    by_norm = {norm(m["name"]): m["url"] for m in index}

    def value_at(current, past, field):
        best = None   # (generation, value): earliest change AFTER the pin gen
        for pv in past:
            g = vggen.get(pv["version_group"]["name"], 99)
            if g > PIN_GEN and pv.get(field) is not None:
                if best is None or g < best[0]:
                    best = (g, pv[field])
        return best[1] if best else current

    targets = [(k, v) for k, v in moves.items()
               if (v.get("power_main") is not None or v.get("accuracy_main") is not None)
               and v["names"]["e"] not in SKIP]

    def one(kv):
        k, v = kv
        url = by_norm.get(norm(v["names"]["e"]))
        if not url:
            return None
        m = get(url)
        return (k, value_at(m["power"], m["past_values"], "power"),
                value_at(m["accuracy"], m["past_values"], "accuracy"))

    changed = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        for r in ex.map(one, targets):
            if not r:
                continue
            k, power, acc = r
            rec = moves[k]
            before = (rec.get("power_main"), rec.get("accuracy_main"))
            if power is not None and rec.get("power_main") is not None:
                rec["power_main"] = power
            # 0 is the curated "never misses" marker — leave those alone.
            if acc is not None and rec.get("accuracy_main") not in (None, 0):
                rec["accuracy_main"] = acc
            after = (rec.get("power_main"), rec.get("accuracy_main"))
            if before != after:
                changed += 1
                print(f"  {rec['names']['e']}: {before[0]}/{before[1]} -> {after[0]}/{after[1]}")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(moves, f, ensure_ascii=False, separators=(",", ":"))
    print(f"pinned {changed} moves to gen {PIN_GEN} values "
          f"(e.g. Bubble power_main = {moves['16']['power_main']})")


if __name__ == "__main__":
    main()
