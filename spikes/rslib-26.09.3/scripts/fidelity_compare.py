#!/usr/bin/env python3
"""Compare two fidelity snapshots. Prints a JSON diff. Exit 0 always; callers inspect the JSON."""

from __future__ import annotations

import json
import sys


def by_guid(notes: list[dict]) -> dict[str, dict]:
    return {note["guid"]: note for note in notes if "guid" in note}


def card_key(cards: list[dict], notes: list[dict]) -> dict[tuple, dict]:
    nid_to_guid = {note["id"]: note["guid"] for note in notes if "id" in note and "guid" in note}
    out = {}
    for card in cards:
        if "nid" not in card:
            continue
        guid = nid_to_guid.get(card["nid"], f"nid:{card['nid']}")
        out[(guid, card.get("ord"))] = card
    return out


def nt_by_name(notetypes: list[dict]) -> dict[str, dict]:
    return {nt["name"]: nt for nt in notetypes if "name" in nt}


def deck_by_name(decks: list[dict]) -> dict[str, dict]:
    return {deck["name"]: deck for deck in decks if "name" in deck}


def compare(src: dict, dst: dict) -> dict:
    src_notes = by_guid(src.get("notes") or [])
    dst_notes = by_guid(dst.get("notes") or [])
    missing = sorted(set(src_notes) - set(dst_notes))
    extra = sorted(set(dst_notes) - set(src_notes))
    field_mismatch = []
    tag_mismatch = []
    id_changed = []
    mid_changed = []
    mtime_changed = []
    usn_changed = []
    csum_changed = []
    sfld_changed = []
    for guid, note in sorted(src_notes.items()):
        other = dst_notes.get(guid)
        if not other:
            continue
        if note.get("fields") != other.get("fields"):
            field_mismatch.append({"guid": guid, "src": note.get("fields"), "dst": other.get("fields")})
        if sorted(note.get("tag_list") or []) != sorted(other.get("tag_list") or []):
            tag_mismatch.append({"guid": guid, "src": note.get("tag_list"), "dst": other.get("tag_list")})
        if note.get("id") != other.get("id"):
            id_changed.append({"guid": guid, "src": note.get("id"), "dst": other.get("id")})
        if note.get("mid") != other.get("mid"):
            mid_changed.append({"guid": guid, "src": note.get("mid"), "dst": other.get("mid")})
        if note.get("mod") != other.get("mod"):
            mtime_changed.append({"guid": guid, "src": note.get("mod"), "dst": other.get("mod")})
        if note.get("usn") != other.get("usn"):
            usn_changed.append({"guid": guid, "src": note.get("usn"), "dst": other.get("usn")})
        if note.get("csum") != other.get("csum"):
            csum_changed.append({"guid": guid, "src": note.get("csum"), "dst": other.get("csum")})
        if note.get("sfld") != other.get("sfld"):
            sfld_changed.append({"guid": guid, "src": note.get("sfld"), "dst": other.get("sfld")})

    src_cards = card_key(src.get("cards") or [], src.get("notes") or [])
    dst_cards = card_key(dst.get("cards") or [], dst.get("notes") or [])
    card_missing = sorted([list(k) for k in set(src_cards) - set(dst_cards)])
    card_extra = sorted([list(k) for k in set(dst_cards) - set(src_cards)])
    card_id_changed = []
    card_ord_mismatch = []
    schedule_residue = []
    deck_of_card_changed = []
    for key, card in sorted(src_cards.items(), key=lambda item: (str(item[0][0]), item[0][1] or 0)):
        other = dst_cards.get(key)
        if not other:
            continue
        if card.get("id") != other.get("id"):
            card_id_changed.append({"key": list(key), "src": card.get("id"), "dst": other.get("id")})
        if card.get("ord") != other.get("ord"):
            card_ord_mismatch.append({"key": list(key), "src": card.get("ord"), "dst": other.get("ord")})
        if card.get("did") != other.get("did"):
            deck_of_card_changed.append({"key": list(key), "src": card.get("did"), "dst": other.get("did")})
        residue = {}
        for field in ("type", "queue", "due", "ivl", "factor", "reps", "lapses", "left", "data"):
            if card.get(field) != other.get(field):
                residue[field] = {"src": card.get(field), "dst": other.get(field)}
        if residue:
            schedule_residue.append({"key": list(key), "diff": residue})

    src_nt = nt_by_name(src.get("notetypes") or [])
    dst_nt = nt_by_name(dst.get("notetypes") or [])
    nt_missing = sorted(set(src_nt) - set(dst_nt))
    nt_extra = sorted(set(dst_nt) - set(src_nt))
    nt_fields = []
    nt_id_changed = []
    for name, nt in sorted(src_nt.items()):
        other = dst_nt.get(name)
        if not other:
            continue
        if nt.get("id") != other.get("id"):
            nt_id_changed.append({"name": name, "src": nt.get("id"), "dst": other.get("id")})
        src_fields = [(f.get("ord"), f.get("name")) for f in nt.get("fields") or []]
        dst_fields = [(f.get("ord"), f.get("name")) for f in other.get("fields") or []]
        src_tmpl = [(t.get("ord"), t.get("name")) for t in nt.get("templates") or []]
        dst_tmpl = [(t.get("ord"), t.get("name")) for t in other.get("templates") or []]
        if src_fields != dst_fields or src_tmpl != dst_tmpl:
            nt_fields.append(
                {
                    "name": name,
                    "src_fields": src_fields,
                    "dst_fields": dst_fields,
                    "src_templates": src_tmpl,
                    "dst_templates": dst_tmpl,
                }
            )

    src_decks = deck_by_name(src.get("decks") or [])
    dst_decks = deck_by_name(dst.get("decks") or [])
    deck_missing = sorted(set(src_decks) - set(dst_decks))
    deck_extra = sorted(set(dst_decks) - set(src_decks))
    deck_id_changed = []
    for name, deck in sorted(src_decks.items()):
        other = dst_decks.get(name)
        if other and deck.get("id") != other.get("id"):
            deck_id_changed.append({"name": name, "src": deck.get("id"), "dst": other.get("id")})

    src_media = src.get("media") or {}
    dst_media = dst.get("media") or {}
    media_missing = sorted(set(src_media) - set(dst_media))
    media_extra = sorted(set(dst_media) - set(src_media))
    media_hash = []
    for name in sorted(set(src_media) & set(dst_media)):
        if src_media[name].get("sha1") != dst_media[name].get("sha1"):
            media_hash.append({"name": name, "src": src_media[name], "dst": dst_media[name]})

    return {
        "notes": {
            "src": len(src_notes),
            "dst": len(dst_notes),
            "missing_guids": missing,
            "extra_guids": extra,
            "field_mismatch": field_mismatch,
            "tag_mismatch": tag_mismatch,
            "id_changed": id_changed,
            "mid_changed": mid_changed,
            "mtime_changed": mtime_changed,
            "usn_changed": usn_changed,
            "csum_changed": csum_changed,
            "sfld_changed": sfld_changed,
        },
        "cards": {
            "src": len(src_cards),
            "dst": len(dst_cards),
            "missing": card_missing,
            "extra": card_extra,
            "id_changed": card_id_changed,
            "ord_mismatch": card_ord_mismatch,
            "deck_id_changed": deck_of_card_changed,
            "schedule_or_state_diff": schedule_residue,
        },
        "notetypes": {
            "missing": nt_missing,
            "extra": nt_extra,
            "id_changed": nt_id_changed,
            "schema_mismatch": nt_fields,
        },
        "decks": {
            "missing": deck_missing,
            "extra": deck_extra,
            "id_changed": deck_id_changed,
        },
        "media": {
            "missing": media_missing,
            "extra": media_extra,
            "hash_mismatch": media_hash,
            "src_names": sorted(src_media),
            "dst_names": sorted(dst_media),
        },
        "revlog": {"src": src.get("revlog_count"), "dst": dst.get("revlog_count")},
        "deck_config_count": {
            "src": src.get("deck_config_count"),
            "dst": dst.get("deck_config_count"),
        },
    }


def main() -> None:
    src = json.loads(PathText(sys.argv[1]))
    dst = json.loads(PathText(sys.argv[2]))
    json.dump(compare(src, dst), sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def PathText(path: str) -> str:
    from pathlib import Path

    return Path(path).read_text()


if __name__ == "__main__":
    main()
