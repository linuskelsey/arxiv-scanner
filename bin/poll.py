#!/usr/bin/env python3
"""
Backend poller for the arxiv-scanner plugin.
Invoked daily by the omarchy-arxiv-scanner systemd --user timer (and on
demand from the bar widget's Refresh button).

Fetches arXiv's new-submissions digest for a configurable category, asks a
headless Claude Code call to rank it against the user's interest areas (and
to write a short summary for each pick), and separately checks every
candidate's author list against a watched-authors list — those get a second,
smaller Claude call just for summaries, since they skip relevance ranking
entirely. Writes ~/.local/state/omarchy-arxiv-scanner/state.json for the QML
bar widget to read, and fires a desktop notification when new matches are
found.
"""
import json
import re
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

STATE_DIR = Path.home() / ".local/state/omarchy-arxiv-scanner"
STATE_FILE = STATE_DIR / "state.json"
CONFIG_DIR = Path.home() / ".config/omarchy-arxiv-scanner"
CONFIG_FILE = CONFIG_DIR / "config.json"
NOTIFIED_ID_CAP = 1000
# arXiv's new-submissions RSS for one category is a few hundred KB at most.
# Cap well above that so a misbehaving/compromised endpoint can't force an
# unbounded read into memory.
MAX_FEED_BYTES = 5_000_000
# A batch of paper summaries should be a few KB of JSON. Truncate before any
# parsing or storage so a runaway Claude process can't get unbounded output
# written into the persistent state file.
MAX_CLAUDE_OUTPUT_CHARS = 200_000

DEFAULT_CONFIG = {
    "category": "quant-ph",
    "interestAreas": [
        "QKD (quantum key distribution)",
        "PQC (post-quantum cryptography)",
        "quantum communications",
        "quantum network architecture",
    ],
    "maxAreaMatches": 3,
    "maxWatchedMatches": 3,
    "watchedAuthors": [],
}

RSS_NS = {
    "arxiv": "http://arxiv.org/schemas/atom",
    "dc": "http://purl.org/dc/elements/1.1/",
}


def log(msg: str) -> None:
    print(f"[arxiv-scanner] {msg}", file=sys.stderr)


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def write_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_FILE)


def load_config() -> dict:
    config = dict(DEFAULT_CONFIG)
    if not CONFIG_FILE.exists():
        return config
    try:
        data = json.loads(CONFIG_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return config
    if isinstance(data.get("category"), str) and data["category"].strip():
        config["category"] = data["category"].strip()
    if isinstance(data.get("interestAreas"), list):
        areas = [a.strip() for a in data["interestAreas"] if isinstance(a, str) and a.strip()]
        if areas:
            config["interestAreas"] = areas
    for key in ("maxAreaMatches", "maxWatchedMatches"):
        try:
            n = int(data.get(key))
            if n >= 0:
                config[key] = n
        except (TypeError, ValueError):
            pass
    if isinstance(data.get("watchedAuthors"), list):
        config["watchedAuthors"] = [a.strip() for a in data["watchedAuthors"] if isinstance(a, str) and a.strip()]
    return config


def fetch_candidates(category: str) -> list[dict]:
    feed_url = f"https://rss.arxiv.org/rss/{category}"
    req = urllib.request.Request(feed_url, headers={"User-Agent": "omarchy-arxiv-scanner/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read(MAX_FEED_BYTES + 1)
    if len(raw) > MAX_FEED_BYTES:
        raise ValueError(f"feed response exceeded {MAX_FEED_BYTES} bytes, aborting")
    root = ET.fromstring(raw)

    candidates = []
    for item in root.findall(".//item"):
        announce_type = item.findtext("arxiv:announce_type", default="", namespaces=RSS_NS)
        if announce_type != "new":
            continue  # skip cross-listings and replacements, matching /list/<category>/new

        link = (item.findtext("link", default="") or "").strip()
        title = " ".join((item.findtext("title", default="") or "").split())
        description = item.findtext("description", default="") or ""
        abstract = re.sub(r"^.*?Abstract:\s*", "", description, flags=re.DOTALL).strip()
        guid = (item.findtext("guid", default="") or link).strip()
        creators = (item.findtext("dc:creator", default="", namespaces=RSS_NS) or "").strip()
        creator_list = [c.strip() for c in creators.split(",") if c.strip()]
        lead_author = creator_list[0] if creator_list else ""
        has_coauthors = len(creator_list) > 1

        pub_date_raw = item.findtext("pubDate", default="") or ""
        try:
            published = parsedate_to_datetime(pub_date_raw).isoformat()
        except (TypeError, ValueError):
            published = ""

        candidates.append({
            "id": guid,
            "title": title,
            "summary": " ".join(abstract.split())[:600],
            "link": link,
            "lead_author": lead_author,
            "has_coauthors": has_coauthors,
            "authors": creator_list,
            "published": published,
        })
    return candidates


def watched_author_matches(candidates: list[dict], watched: list[str]) -> list[dict]:
    if not watched:
        return []
    matches = []
    for c in candidates:
        for author in c.get("authors", []):
            author_l = author.lower()
            for name in watched:
                name_l = name.lower()
                if name_l in author_l or author_l in name_l:
                    matches.append({
                        "id": c["id"],
                        "title": c["title"],
                        "link": c["link"],
                        "lead_author": c.get("lead_author", ""),
                        "has_coauthors": c.get("has_coauthors", False),
                        "published": c.get("published", ""),
                        # The paper's own author-list entry that matched —
                        # worth keeping distinct from lead_author, since a
                        # watched name can match a co-author further down
                        # the list, not whoever's listed first.
                        "matched_author": author,
                        "watched": True,
                        # Consumed by main()'s summarize_papers() call and
                        # dropped before this dict is ever written to state —
                        # watched hits skip classify() entirely, so nothing
                        # else has read the abstract for them yet.
                        "_abstract": c.get("summary", ""),
                    })
                    break
            else:
                continue
            break
    matches.sort(key=lambda m: m["published"], reverse=True)
    return matches


def build_summary_prompt(papers: list[dict]) -> str:
    entries = "\n\n".join(
        f"[{i}] id={p['id']}\ntitle: {p['title']}\nabstract: {p['abstract']}"
        for i, p in enumerate(papers)
    )
    return f"""Summarize each of the following paper abstracts in exactly ONE sentence:
what the paper actually does or finds, not why it might matter to anyone.
The sentence can be information-dense and run long — it renders across 2-3
lines in a narrow UI column, it does not need to fit on one visual line.
No markdown, no hedging, no restating the title, no second sentence.
Return ONLY a JSON array (no prose, no markdown fences), one element per paper:
{{"id": "<paper id, copied exactly>", "summary": "<one sentence>"}}

{entries}"""


def naive_summary(abstract: str, max_sentences: int = 1) -> str:
    sentences = re.split(r"(?<=[.!?])\s+", abstract.strip())
    return " ".join(sentences[:max_sentences]).strip()


def summarize_papers(papers: list[dict]) -> dict[str, str]:
    """
    papers: [{"id":..., "title":..., "abstract":...}, ...]. One batched
    Claude call covering all of them (cheap: only ever called on the small
    set of papers actually selected for display, never the full candidate
    pool). Falls back to a naive first-N-sentences trim per paper if Claude
    fails or skips one, so the UI always has *something* coherent rather
    than an empty description line.
    """
    if not papers:
        return {}
    summaries: dict[str, str] = {}
    try:
        result = subprocess.run(
            ["claude", "-p", "--output-format", "text"],
            input=build_summary_prompt(papers),
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode == 0:
            stdout = result.stdout[:MAX_CLAUDE_OUTPUT_CHARS]
            match = re.search(r"\[.*\]", stdout.strip(), re.DOTALL)
            if match:
                for item in json.loads(match.group(0)):
                    if isinstance(item, dict) and item.get("id"):
                        summaries[item["id"]] = item.get("summary", "")
        else:
            log(f"summarize: claude exited {result.returncode}: {result.stderr[:300]}")
    except (subprocess.SubprocessError, OSError, json.JSONDecodeError) as e:
        log(f"summarize failed: {e}")

    for p in papers:
        if not summaries.get(p["id"]):
            summaries[p["id"]] = naive_summary(p.get("abstract", ""))
    return summaries


def build_prompt(candidates: list[dict], interest_areas: list[str]) -> str:
    areas = "\n".join(f"- {a}" for a in interest_areas)
    papers = "\n\n".join(
        f"[{i}] id={c['id']}\ntitle: {c['title']}\nabstract: {c['summary']}"
        for i, c in enumerate(candidates)
    )
    return f"""You are filtering today's new arXiv submissions for relevance
to these interest areas:
{areas}

Below are {len(candidates)} candidate papers, each with an index, id, title, and abstract.
Return ONLY a JSON array (no prose, no markdown fences) of the papers that are
genuinely relevant to one or more of the interest areas above, ORDERED from
MOST to LEAST relevant. Each element:
{{"id": "<paper id, copied exactly>", "summary": "<ONE sentence — can run long, it wraps across 2-3 lines in a narrow UI column — summarizing what the paper actually does or finds, not why it's relevant>"}}
Omit papers that only tangentially mention the general field without touching
the listed areas. Return [] if none match.

{papers}"""


def classify(candidates: list[dict], interest_areas: list[str]) -> list[dict]:
    if not candidates or not interest_areas:
        return []
    prompt = build_prompt(candidates, interest_areas)
    try:
        result = subprocess.run(
            ["claude", "-p", "--output-format", "text"],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=180,
        )
    except (subprocess.SubprocessError, OSError) as e:
        log(f"claude invocation failed: {e}")
        return []

    if result.returncode != 0:
        log(f"claude exited {result.returncode}: {result.stderr[:400]}")
        return []

    text = result.stdout[:MAX_CLAUDE_OUTPUT_CHARS].strip()
    match = re.search(r"\[.*\]", text, re.DOTALL)
    if not match:
        log(f"no JSON array in claude output: {text[:400]}")
        return []

    try:
        parsed = json.loads(match.group(0))
    except json.JSONDecodeError as e:
        log(f"bad JSON from claude: {e}")
        return []

    by_id = {c["id"]: c for c in candidates}
    matches = []
    for item in parsed:  # preserves Claude's most-to-least-relevant ordering
        if not isinstance(item, dict):
            continue
        cid = item.get("id")
        base = by_id.get(cid)
        if not base:
            continue
        matches.append({
            "id": cid,
            "title": base["title"],
            "link": base["link"],
            "lead_author": base.get("lead_author", ""),
            "has_coauthors": base.get("has_coauthors", False),
            "published": base.get("published", ""),
            "summary": item.get("summary", ""),
            "watched": False,
        })
    return matches


def notify(new_matches: list[dict]) -> None:
    if not new_matches:
        return
    if len(new_matches) == 1:
        title = "1 new arXiv paper matches your interests"
        body = new_matches[0]["title"]
    else:
        title = f"{len(new_matches)} new arXiv papers match your interests"
        body = "\n".join(f"- {m['title']}" for m in new_matches[:5])
    try:
        subprocess.run(
            ["omarchy", "notification", "send", "--app-name", "arXiv Scanner", "-u", "normal", title, body],
            check=False,
            timeout=10,
        )
    except (subprocess.SubprocessError, OSError) as e:
        log(f"notification failed: {e}")


def main() -> None:
    prev = load_state()
    notified_ids = prev.get("_notified_ids", [])
    config = load_config()

    try:
        candidates = fetch_candidates(config["category"])
    except Exception as e:
        log(f"fetch failed for category '{config['category']}': {e}")
        return

    log(f"{len(candidates)} new-submission candidate(s) from today's '{config['category']}' feed")

    todays_watched = watched_author_matches(candidates, config["watchedAuthors"])
    watched_ids = {m["id"] for m in todays_watched}

    if todays_watched:
        to_summarize = [{"id": m["id"], "title": m["title"], "abstract": m.pop("_abstract", "")} for m in todays_watched]
        summaries = summarize_papers(to_summarize)
        for m in todays_watched:
            m["summary"] = summaries.get(m["id"], "")

    # This scan only ever sees *today's* feed, but the watched-authors column
    # is meant to read as "their N most recent papers" regardless of when
    # each scan ran — so merge into whatever's already there (including
    # check-authors.py's on-demand backfill) instead of replacing it outright,
    # or a paper found today would just get evicted by tomorrow's empty scan.
    by_id = {m["id"]: m for m in prev.get("watched_matches", [])}
    for m in todays_watched:
        by_id[m["id"]] = m
    watched_matches = sorted(by_id.values(), key=lambda m: m["published"], reverse=True)
    watched_matches = watched_matches[:config["maxWatchedMatches"]]

    area_matches_all = classify(candidates, config["interestAreas"])
    # A watched-author hit already gets its own slot; don't let it also
    # occupy one of the scarce top-N relevance slots.
    area_matches = [m for m in area_matches_all if m["id"] not in watched_ids][:config["maxAreaMatches"]]

    log(f"{len(todays_watched)} watched-author match(es) today, {len(watched_matches)} shown after merge, "
        f"{len(area_matches)} interest-area match(es) (of {len(area_matches_all)} found)")

    matches = area_matches + watched_matches
    new_matches = [m for m in matches if m["id"] not in notified_ids]
    notify(new_matches)

    notified_ids = (notified_ids + [m["id"] for m in new_matches])[-NOTIFIED_ID_CAP:]

    write_state({
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "area_matches": area_matches,
        "watched_matches": watched_matches,
        "_notified_ids": notified_ids,
    })


if __name__ == "__main__":
    main()
