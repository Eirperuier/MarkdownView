#!/usr/bin/env python3
"""Exports the floo services the demo shows, as the floo server publishes them: each
definition with its hand-kept copy laid over it (floo docs/app.md 3.2), keeping only what
the service pages read. Run from anywhere:

    python3 -I DemoApp/Scripts/floo-catalog.py ~/Developer/floo
"""
import json
import os
import sys

SERVICES = ["gmail", "googlecalendar", "github", "notion", "slack",
            "calendar", "reminders", "contacts", "photos", "health", "codex"]
TEXT = ["name", "short_description", "description", "prompts"]


def overlaid(presentation, copy):
    # ServiceDefinition.withCopy(from:): field by field, language by language.
    result = dict(presentation)
    for key, value in copy.items():
        if key == "localized":
            for locale, text in value.items():
                result.setdefault("localized", {})
                result["localized"][locale] = {**result["localized"].get(locale, {}), **text}
        else:
            result[key] = value
    return result


def main(floo):
    catalog = os.path.join(floo, "Catalog")
    out = []
    for service in SERVICES:
        path = os.path.join(catalog, f"{service}.json")
        if not os.path.exists(path):
            path = os.path.join(catalog, "composio", f"{service}.json")
        with open(path, encoding="utf-8") as file:
            definition = json.load(file)
        copy_path = os.path.join(catalog, "presentation", f"{service}.json")
        presentation = definition["presentation"]
        if os.path.exists(copy_path):
            with open(copy_path, encoding="utf-8") as file:
                presentation = overlaid(presentation, json.load(file))
        out.append({
            "id": service,
            "presentation": presentation,
            "operations": [{"title": o.get("title") or o["id"], "effect": o["effect"]}
                           for o in definition["operations"]],
            "hooks": [{"summary": h.get("summary", "")} for h in definition.get("hooks", [])],
        })
    target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "DemoApp",
                          "Destinations", "Floo", "FlooCatalog.json")
    with open(target, "w", encoding="utf-8") as file:
        json.dump(out, file, ensure_ascii=False, indent=1, sort_keys=True)
        file.write("\n")


main(os.path.expanduser(sys.argv[1]))
