#!/usr/bin/env python3
"""
Fetch mainline move descriptions + priority from PokeAPI and merge them into
../gamedata/moves.json and ../Localizable/{ko,ja}.lproj/Localizable.strings.

The shipped `desc` fields (and their ko/ja move.desc.* translations) were the
EoS dungeon texts — tile ranges, rooms, bellies — which read wrong next to
the mainline battle mechanics the engine actually runs (user report: Quick
Attack said "up to 2 tiles away" instead of "always strikes first"). This
replaces every matched move's text with the official mainline flavor text
(newest version group that carries the language), and merges the mainline
priority bracket as `priority` (stored only when nonzero) so the engine's
turn order comes from data instead of a hand-kept table.

Same CSV source and name-matching scheme as fetch_contact.py / fetch_accuracy.py.
One-time collection; the app ships the merged JSON + strings.
"""
from __future__ import annotations

import csv
import io
import json
import os
import re
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEST = os.path.join(ROOT, "gamedata")
CSV_BASE = "https://raw.githubusercontent.com/PokeAPI/pokeapi/master/data/v2/csv"
LANGS = ("e", "k", "j")   # JSON `desc` gets English; ko/ja go to .strings


def get_text(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pokemon-mouse-follower/1.0"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read().decode("utf-8")
        except Exception:
            if attempt == 4:
                raise
            time.sleep(2 ** attempt)


def get_json(url):
    return json.loads(get_text(url))


def norm(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


ALIAS = {
    "faintattack": "feintattack",
    "hijumpkick": "highjumpkick",
    "smellingsalt": "smellingsalts",
}


def clean(text: str, lang: str) -> str:
    """Official flavor text -> one panel-wrappable line. Japanese keeps its
    ideographic spacing; the line/page breaks just disappear there."""
    text = text.replace("­", "")
    text = re.sub(r"[\n\f]+", "" if lang == "ja" else " ", text)
    return re.sub(r" {2,}", " ", text).strip()


# Games that dropped a move ship a "This move can't be used." placeholder
# instead of its text — fall back past those to the newest REAL description.
PLACEHOLDERS = ("This move can't be used.", "This move can’t be used.",
                "사용할 수 없는 기술입니다", "つかえない　わざです", "使えない技です")


def pick_flavor(entries, lang: str) -> str | None:
    """The newest version group's real text in `lang`."""
    best, best_vg = None, -1
    for ft in entries:
        if ft["language"]["name"] != lang:
            continue
        if any(p in ft["flavor_text"] for p in PLACEHOLDERS):
            continue
        vg = int(ft["version_group"]["url"].rstrip("/").rsplit("/", 1)[-1])
        if vg > best_vg:
            best, best_vg = ft["flavor_text"], vg
    return clean(best, lang) if best else None


def rewrite_strings(lproj: str, descs: dict[int, str]):
    """Replace existing move.desc.<id> lines in place (layout untouched)."""
    path = os.path.join(ROOT, "Localizable", lproj, "Localizable.strings")
    lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
    pat = re.compile(r'^"move\.desc\.(\d+)" = ".*";')
    replaced = 0
    for i, line in enumerate(lines):
        m = pat.match(line)
        if not m:
            continue
        mid = int(m.group(1))
        if mid in descs:
            text = descs[mid].replace("\\", "\\\\").replace('"', '\\"')
            lines[i] = f'"move.desc.{mid}" = "{text}";\n'
            replaced += 1
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(lines))
    print(f"{lproj}: rewrote {replaced} move.desc entries")


def main():
    rows = list(csv.DictReader(io.StringIO(get_text(f"{CSV_BASE}/moves.csv"))))
    ident_by_norm = {norm(r["identifier"]): r["identifier"] for r in rows
                     if int(r["id"]) < 10000}   # skip shadow/special forms

    path = os.path.join(DEST, "moves.json")
    moves = json.load(open(path, encoding="utf-8"))
    matched = []
    for key, mv in moves.items():
        n = norm(mv["names"].get("e", ""))
        n = ALIAS.get(n, n)
        if n in ident_by_norm:
            matched.append((key, ident_by_norm[n]))

    def one(pair):
        key, ident = pair
        d = get_json(f"https://pokeapi.co/api/v2/move/{ident}/")
        return key, {
            "priority": d["priority"],
            "en": pick_flavor(d["flavor_text_entries"], "en"),
            "ko": pick_flavor(d["flavor_text_entries"], "ko"),
            "ja": pick_flavor(d["flavor_text_entries"], "ja"),
        }

    print(f"fetching {len(matched)} matched moves...")
    results = {}
    with ThreadPoolExecutor(max_workers=4) as ex:
        for i, (key, data) in enumerate(ex.map(one, matched)):
            results[key] = data
            if (i + 1) % 100 == 0:
                print(f"  ...{i + 1}/{len(matched)}")

    desc_en = desc_ko = desc_ja = prio = 0
    ko_out, ja_out = {}, {}
    for key, data in results.items():
        mv = moves[key]
        if data["en"]:
            mv["desc"] = data["en"]
            desc_en += 1
        if data["ko"]:
            ko_out[int(key)] = data["ko"]
            desc_ko += 1
        if data["ja"]:
            ja_out[int(key)] = data["ja"]
            desc_ja += 1
        if data["priority"]:
            mv["priority"] = data["priority"]
            prio += 1
        else:
            mv.pop("priority", None)

    with open(path, "w", encoding="utf-8") as f:
        json.dump(moves, f, ensure_ascii=False, separators=(",", ":"))
    print(f"moves.json: desc(en) for {desc_en}, priority for {prio} moves")

    rewrite_strings("ko.lproj", ko_out)
    rewrite_strings("ja.lproj", ja_out)
    print(f"(ko texts fetched: {desc_ko}, ja: {desc_ja})")


if __name__ == "__main__":
    main()
