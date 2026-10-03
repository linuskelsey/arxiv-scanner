#!/usr/bin/env python3
"""
Validates the watched-authors list against arXiv itself: for each name,
queries arXiv's search API scoped to the configured category so typos or
name-format mismatches (arXiv wants "Firstname Lastname") show up immediately
instead of silently matching nothing for months. Also surfaces each author's
papers from the last 30 days in that category right away, since the daily
scan (poll.py) only ever looks at *today's* new-submissions feed and has no
historical lookback — this is the only way to backfill. Backfilled abstracts
are run through poll.py's summarize_papers() (one batched Claude call) so
they show the same one-sentence summary style as everything else, not the
raw abstract.

Invoked on demand from the bar widget's "Check authors" button via
`bar.run(...)`. Writes its own author_check.json (the inline found/not-found
report in Settings) and also merges the backfilled papers into state.json's
watched_matches, via poll.load_state/write_state, so they show up in the
popup immediately rather than waiting on a coincidental same-day scan hit.

Usage: check-authors.py --authors "Name One, Name Two" --category quant-ph [--max-per-author 3]
"""
import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import poll  # noqa: E402 — same-directory script, reused for state/config I/O

STATE_DIR = Path.home() / ".local/state/omarchy-arxiv-quantum"
RESULT_FILE = STATE_DIR / "author_check.json"

ATOM_NS = {"a": "http://www.w3.org/2005/Atom", "os": "http://a9.com/-/spec/opensearch/1.1/"}
# Be polite to arXiv's free API between sequential per-author queries.
REQUEST_GAP_SECONDS = 3
# Backfill for a newly-watched author is a convenience, not a full archive
# dig — cap how far back the "recent papers" list can reach. Validation
# (found / total_count) stays unbounded so a prolific-but-currently-quiet
# author still confirms as a real, correctly-spelled name.
# Shared with poll.py's persistent watched-candidates superset (imported
# rather than a separate constant here) — that superset shouldn't outlive
# what this backfill itself would consider "recent" for the same author.
MAX_BACKFILL_DAYS = poll.MAX_WATCHED_CANDIDATE_AGE_DAYS
# arXiv's per-author API response is small (a handful of entries). Cap well
# above that so a misbehaving/compromised endpoint can't force an unbounded
# read into memory.
MAX_RESPONSE_BYTES = 5_000_000


def log(msg: str) -> None:
    print(f"[arxiv-quantum] {msg}", file=sys.stderr)


def query_author(name: str, category: str, max_results: int) -> dict:
    query = f'au:"{name}" AND cat:{category}'
    params = urllib.parse.urlencode({
        "search_query": query,
        "sortBy": "submittedDate",
        "sortOrder": "descending",
        "max_results": max_results,
    })
    url = f"https://export.arxiv.org/api/query?{params}"
    req = urllib.request.Request(url, headers={"User-Agent": "omarchy-arxiv-quantum/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ValueError(f"response exceeded {MAX_RESPONSE_BYTES} bytes, aborting")
    except Exception as e:
        log(f"query failed for '{name}': {e}")
        return {"name": name, "found": False, "total_count": 0, "recent": [], "error": str(e)}

    root = ET.fromstring(raw)
    total_text = root.findtext("os:totalResults", default="0", namespaces=ATOM_NS)
    total_count = int(total_text) if total_text.isdigit() else 0

    cutoff = datetime.now(timezone.utc) - timedelta(days=MAX_BACKFILL_DAYS)
    recent = []
    for entry in root.findall("a:entry", ATOM_NS):
        arxiv_id = (entry.findtext("a:id", default="", namespaces=ATOM_NS) or "").strip()
        if not arxiv_id:
            continue
        published_raw = entry.findtext("a:published", default="", namespaces=ATOM_NS)
        try:
            published_dt = datetime.strptime(published_raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if published_dt < cutoff:
            # Results are sorted most-recent-first, so once we're past the
            # cutoff every remaining entry is older still — stop here.
            break
        title = poll.normalize_latex_accents(" ".join((entry.findtext("a:title", default="", namespaces=ATOM_NS) or "").split()))
        abstract = poll.normalize_latex_accents(" ".join((entry.findtext("a:summary", default="", namespaces=ATOM_NS) or "").split()))
        authors = [
            (a.findtext("a:name", default="", namespaces=ATOM_NS) or "").strip()
            for a in entry.findall("a:author", ATOM_NS)
        ]
        authors = [a for a in authors if a]
        recent.append({
            "id": arxiv_id,
            "title": title,
            "link": arxiv_id.replace("http://arxiv.org", "https://arxiv.org"),
            "published": published_raw,
            "lead_author": authors[0] if authors else "",
            "has_coauthors": len(authors) > 1,
            "abstract": abstract,  # raw; summarize_papers() replaces this with "summary" before use
        })

    return {
        "name": name,
        "found": total_count > 0,
        "total_count": total_count,
        "recent": recent,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--authors", default="")
    parser.add_argument("--category", default="quant-ph")
    parser.add_argument("--max-per-author", type=int, default=3)
    args = parser.parse_args()

    names = [n.strip() for n in args.authors.split(",") if n.strip()]
    if not names:
        log("no authors given")
        return

    # Growing a watched-authors list from N to N+1 used to re-query every
    # existing name from scratch (with a rate-limit sleep before each),
    # even though only the new one actually needs verifying. A name already
    # confirmed to exist in this category isn't going to stop existing —
    # only cache positive results, not negative ones, since an author with
    # zero papers today could plausibly publish their first tomorrow and a
    # cached "not found" would incorrectly keep hiding that.
    cache = poll.load_author_cache()
    results = []
    queried_live = 0
    for name in names:
        key = poll.author_cache_key(name, args.category)
        cached = cache.get(key)
        if cached:
            log(f"'{name}' already verified for cat:{args.category} — skipping live check")
            results.append({
                "name": name,
                "found": True,
                "total_count": cached.get("total_count", 0),
                # Not re-fetched for an already-verified author: poll.py's
                # regular scan keeps their persistent candidate superset
                # current going forward, so this is only ever needed once
                # per author, not on every re-check of the whole list.
                "recent": [],
                "cached": True,
            })
            continue
        if queried_live > 0:
            time.sleep(REQUEST_GAP_SECONDS)
        queried_live += 1
        log(f"checking '{name}' in cat:{args.category}")
        result = query_author(name, args.category, args.max_per_author)
        results.append(result)
        if result.get("found"):
            cache[key] = {
                "total_count": result.get("total_count", 0),
                "verified_at": datetime.now(timezone.utc).isoformat(),
            }
    poll.write_author_cache(cache)

    all_recent = [p for r in results for p in r.get("recent", [])]
    if all_recent:
        summaries = poll.summarize_papers([
            {"id": p["id"], "title": p["title"], "abstract": p.get("abstract", "")}
            for p in all_recent
        ])
        for p in all_recent:
            p["summary"] = summaries.get(p["id"], "")
            del p["abstract"]

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    # See poll.write_state's comment: mkstemp (O_CREAT | O_EXCL), not a
    # predictable "*.json.tmp" that a pre-planted symlink could turn into a
    # write through to an arbitrary file.
    fd, tmp_path = tempfile.mkstemp(dir=STATE_DIR, prefix=".author_check.json.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps({
                "checked_at": datetime.now(timezone.utc).isoformat(),
                "category": args.category,
                "results": results,
            }, indent=2))
        os.replace(tmp_path, RESULT_FILE)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    merge_into_watched_matches(results)


def merge_into_watched_matches(results: list[dict]) -> None:
    """
    check-authors's whole reason to exist is poll.py's daily scan having no
    lookback — a validated author's papers need to actually show up in the
    widget, not just get reported here. Folds each result's backfilled
    "recent" papers into the same persistent watched-candidates superset
    poll.py's own scan writes to (not directly into state.json's displayed
    watched_matches), then recomputes that displayed list as a fresh view
    over the combined superset — same as poll.py's main() — so the popup
    reflects them immediately instead of waiting for a coincidental
    same-day scan hit, and stays consistent with whatever the current
    config's caps/watched-authors list actually is.
    """
    config = poll.load_config()
    state = poll.load_state()

    new_entries = [
        {
            "id": paper["id"],
            "title": paper["title"],
            "link": paper["link"],
            "lead_author": paper.get("lead_author", ""),
            "has_coauthors": paper.get("has_coauthors", False),
            "published": paper.get("published", ""),
            "summary": paper.get("summary", ""),
            "matched_author": result["name"],
            "matched_config_name": result["name"],
            "watched": True,
        }
        for result in results
        for paper in result.get("recent", [])
    ]
    watched_candidates = poll.merge_watched_matches(poll.load_watched_candidates(), new_entries)
    watched_candidates = poll.prune_watched_candidates(watched_candidates)
    poll.write_watched_candidates(watched_candidates)

    merged = poll.filter_watched_for_config(watched_candidates, config["watchedAuthors"])
    merged = poll.cap_per_author(merged, config.get("maxWatchedPerAuthor"))
    merged = sorted(merged, key=lambda m: m["published"], reverse=True)
    merged = merged[:config["maxWatchedMatches"]]
    state["watched_matches"] = merged

    # Backfilled papers are already visible right here in the settings
    # panel — don't also fire a desktop notification for them if tomorrow's
    # regular scan happens to see the same paper in that day's feed.
    notified_ids = set(state.get("_notified_ids", []))
    notified_ids.update(m["id"] for m in merged)
    state["_notified_ids"] = list(notified_ids)[-poll.NOTIFIED_ID_CAP:]

    poll.write_state(state)


if __name__ == "__main__":
    main()
