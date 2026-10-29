#!/usr/bin/env python3
"""Pull Backend service/method indices out of rslib's generated backend.rs.

Indices come from prost descriptors at build time and are not stable across
Anki revisions. The Node and Dart tests load the JSON this script writes.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def newest_backend_rs(roots: list[Path]) -> Path:
    found: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        found.extend(root.glob("target/**/out/backend.rs"))
        found.extend(root.glob("**/build/anki-*/out/backend.rs"))
    if not found:
        raise SystemExit(f"backend.rs not found under {roots}")
    return max(found, key=lambda path: path.stat().st_mtime)


def slice_backend_run_method(text: str) -> str:
    """The Backend impl takes `&self`. Collection's copy takes `&mut self`."""
    marker = "pub fn run_service_method(\n        &self,"
    start = text.find(marker)
    if start < 0:
        marker = "pub fn run_service_method(&self,"
        start = text.find(marker)
    if start < 0:
        raise SystemExit("Backend::run_service_method not found")
    end = text.find("pub fn run_service_method(", start + len(marker))
    if end < 0:
        end = len(text)
    return text[start:end]


def parse(text: str) -> dict:
    backend = slice_backend_run_method(text)
    services: dict[str, dict] = {}
    for match in re.finditer(
        r"(?m)^\s*(\d+) => self\.run_(\w+)_method\(method, input\),",
        backend,
    ):
        services[match.group(2)] = {"index": int(match.group(1)), "methods": {}}

    # Method arms live in `fn run_<service>_method` bodies. Prettyplease keeps
    # the decode/call on a few lines; the call is `Qualifier::rust_name(self`.
    for name, service in services.items():
        func = f"fn run_{name}_method("
        start = text.find(func)
        if start < 0:
            raise SystemExit(f"missing {func}")
        nxt = text.find("\nfn ", start + len(func))
        if nxt < 0:
            nxt = text.find("\nimpl ", start + len(func))
        body = text[start : nxt if nxt > 0 else len(text)]
        for match in re.finditer(
            r"(?s)(\d+) => \{\s*(?:let input = .*?;\s*)?(?:let output = )?([A-Za-z0-9_:]+)::([A-Za-z0-9_]+)\(\s*self\b",
            body,
        ):
            service["methods"][match.group(3)] = int(match.group(1))
    return services


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--search", action="append", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--anki-commit", required=True)
    args = parser.parse_args()
    source = newest_backend_rs(args.search)
    services = parse(source.read_text())
    required = {
        "backend_collection_service": ["open_collection", "close_collection"],
        "backend_import_export_service": ["import_anki_package", "export_anki_package"],
        "backend_notes_service": ["new_note", "add_note", "add_notes", "get_note", "update_notes", "cards_of_note"],
        "backend_notetypes_service": ["get_notetype_id_by_name"],
        "backend_cards_service": ["get_card"],
        "backend_decks_service": ["set_current_deck"],
        "backend_scheduler_service": ["get_queued_cards", "answer_card"],
        "backend_search_service": ["search_cards", "search_notes"],
    }
    missing = []
    for service, methods in required.items():
        if service not in services:
            missing.append(service)
            continue
        for method in methods:
            if method not in services[service]["methods"]:
                missing.append(f"{service}.{method}")
    if missing:
        raise SystemExit(f"missing indices: {missing}")
    payload = {
        "anki_commit": args.anki_commit,
        "source": str(source),
        "services": services,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {args.out} from {source} ({len(services)} services)")


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
