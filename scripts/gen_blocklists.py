#!/usr/bin/env python3
"""Generates the tracking-protection block lists (WebKit content-rule-list JSON).

Mirrors Firefox's ContentBlockingGenerator (BrowserKit/Sources/ContentBlockingGenerator,
MPL-2.0): one third-party "block" rule per Disconnect domain, with the owning entity's own
sites in "unless-domain" so a company's resources still load on its own pages.

Input: mozilla-services/shavar-prod-lists at a pinned commit (Disconnect lists,
CC BY-NC-SA 4.0). Output: App/Resources/BlockLists/disconnect-block-<category>.json.

Usage: python3 scripts/gen_blocklists.py
"""

import json
import pathlib
import urllib.request

COMMIT = "91cf7dd142fc69aabe334a1a6e0091a1db228203"
BASE = f"https://raw.githubusercontent.com/mozilla-services/shavar-prod-lists/{COMMIT}/"
CATEGORIES = {
    "advertising": "normalized-lists/ads-track-digest256.json",
    "analytics": "normalized-lists/analytics-track-digest256.json",
    "social": "normalized-lists/social-track-digest256.json",
    "content": "normalized-lists/content-track-digest256.json",
}
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "App" / "Resources" / "BlockLists"


def fetch_json(path):
    with urllib.request.urlopen(BASE + path, timeout=60) as response:
        return json.load(response)


def entity_map(entity_list):
    """Maps each resource domain to the domains (properties) its owner uses for its own sites."""
    owners = {}
    for entity in entity_list.get("entities", {}).values():
        properties = entity.get("properties", [])
        for resource in entity.get("resources", []):
            owners[resource] = properties
    return owners


def owner_properties(domain, owners):
    if domain in owners:
        return owners[domain]
    # Like Firefox, fall back to an entity resource contained in the domain; prefer the longest
    # match so the output doesn't depend on dictionary order.
    matches = [resource for resource in owners if resource in domain]
    return owners[max(matches, key=len)] if matches else []


def rule(domain, properties):
    trigger = {
        "url-filter": "^https?://([^/]+\\.)?" + domain.replace(".", "\\."),
        "load-type": ["third-party"],
    }
    if properties:
        trigger["unless-domain"] = ["*" + site for site in properties]
    return {"action": {"type": "block"}, "trigger": trigger}


def main():
    owners = entity_map(fetch_json("disconnect-entitylist.json"))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for category, path in CATEGORIES.items():
        domains = fetch_json(path)
        rules = [rule(domain, owner_properties(domain, owners)) for domain in domains]
        lines = ",\n".join(json.dumps(item, separators=(",", ":"), ensure_ascii=False) for item in rules)
        target = OUTPUT / f"disconnect-block-{category}.json"
        target.write_text("[\n" + lines + "\n]\n", encoding="utf-8", newline="\n")
        print(f"{category}: {len(rules)} rules -> {target.name}")

    fonts = [{"action": {"type": "block"}, "trigger": {"url-filter": ".*", "resource-type": ["font"]}}]
    (OUTPUT / "web-fonts.json").write_text(json.dumps(fonts, indent=1) + "\n", encoding="utf-8", newline="\n")
    print("web-fonts: 1 rule -> web-fonts.json")


if __name__ == "__main__":
    main()
