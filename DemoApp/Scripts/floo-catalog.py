#!/usr/bin/env python3
"""Exports the floo services the demo shows, as the floo server shows them: each
definition with its hand-kept words laid over it (floo docs/service-definitions.md §3.4),
keeping only what the service pages read. Composio's definitions are in the floo
repository (Catalog/composio); a device service's is in its code, so it is read from a
folder of their JSON (one file per service, `<id>.json`). Run from anywhere:

    python3 -I DemoApp/Scripts/floo-catalog.py ~/Developer/floo /tmp/floo-definitions

Writes FlooCatalog.json (the pages) and FlooSettings.json (each service's settings format,
the operation its settings page shows above them with that operation's output format, and
the page's words by language: the settings', the operations' answers' properties', and the
sections, docs/service-settings.md §3.2; apart, so their keys are read as they are written).
"""
import json
import os
import sys

SERVICES = ["gmail", "googlecalendar", "github", "notion", "slack",
            "calendar", "reminders", "contacts", "photos", "health", "codex"]
PRESENTATION = ["name", "short_description", "description", "prompts", "developer", "website",
                "privacy_policy", "terms_of_service", "icon", "color", "category"]
TEXT = ["name", "short_description", "description", "prompts"]


def worded(presentation, words):
    # Presentation.overlaid(by:): field by field, language by language.
    result = dict(presentation)
    for key in PRESENTATION:
        if key in words:
            result[key] = words[key]
    for locale, text in words.get("localized", {}).items():
        result.setdefault("localized", {})
        result["localized"][locale] = {**result["localized"].get(locale, {}),
                                       **{k: v for k, v in text.items() if k in TEXT}}
    return result


def page(text):
    # A settings page's words in one language: the settings', each operation's answers'
    # properties', and the sections.
    return {
        "settings": text.get("settings", {}),
        "properties": {operation: words["properties"] for operation, words in text.get("operations", {}).items()
                       if "properties" in words},
        "sections": text.get("sections", []),
    }


def main(floo, definitions):
    catalog = os.path.join(floo, "Catalog")
    pages, settings = [], {}
    for service in SERVICES:
        path = os.path.join(catalog, "composio", f"{service}.json")
        if not os.path.exists(path):
            path = os.path.join(definitions, f"{service}.json")
        with open(path, encoding="utf-8") as file:
            definition = json.load(file)
        words_path = os.path.join(catalog, "words", f"{service}.json")
        words = {}
        if os.path.exists(words_path):
            with open(words_path, encoding="utf-8") as file:
                words = json.load(file)
        operations = words.get("operations", {})
        pages.append({
            "id": service,
            "presentation": worded(definition["presentation"], words),
            "operations": [{"title": operations.get(o["id"], {}).get("title") or o.get("title") or o["id"],
                            "effect": o["effect"]} for o in definition["operations"]],
            "hooks": [{"summary": h.get("summary", "")} for h in definition.get("hooks", [])],
        })
        if definition.get("settings"):
            settings[service] = {
                "format": definition["settings"],
                "words": {locale: page(text) for locale, text in
                          [("en", words), *words.get("localized", {}).items()]},
            }
            info = definition.get("info")
            if info:
                output = next(o.get("output") for o in definition["operations"] if o["id"] == info)
                settings[service]["info"] = {"operation": info, "output": output}
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "DemoApp", "Destinations", "Floo")
    for name, value in [("FlooCatalog.json", pages), ("FlooSettings.json", settings)]:
        with open(os.path.join(here, name), "w", encoding="utf-8") as file:
            json.dump(value, file, ensure_ascii=False, indent=1, sort_keys=True)
            file.write("\n")


main(os.path.expanduser(sys.argv[1]), os.path.expanduser(sys.argv[2]))
