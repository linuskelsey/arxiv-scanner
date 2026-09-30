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
import os
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

STATE_DIR = Path.home() / ".local/state/omarchy-arxiv-scanner"
STATE_FILE = STATE_DIR / "state.json"
# The durable superset of every paper ever found for a watched author —
# distinct from state.json's watched_matches, which is a derived, capped
# VIEW recomputed from this on every scan. Keeping the two separate means
# removing a watched author, or raising a cap, takes effect immediately
# against everything already known, without needing a fresh API backfill.
WATCHED_CANDIDATES_FILE = STATE_DIR / "watched_candidates.json"
MAX_WATCHED_CANDIDATES = 500
# Matches check-authors.py's own backfill lookback (it imports this rather
# than defining a separate constant) — the superset shouldn't hold a paper
# check-authors.py itself would no longer consider "recent" for the same
# author. Not currently user-configurable; queued as a follow-up (would
# need to become a config field both here and in check-authors.py's own
# --max-per-author-style CLI handling).
MAX_WATCHED_CANDIDATE_AGE_DAYS = 30
# Persistent record of which (name, category) pairs check-authors.py has
# already confirmed exist on arXiv, so re-running it after adding one more
# watched author doesn't re-query everyone already verified.
AUTHOR_CACHE_FILE = STATE_DIR / "author_verify_cache.json"
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
    # None = no per-author cap: with several watched authors, a global
    # top-N-most-recent-overall cap lets whoever publishes most often or
    # most recently crowd the rest out of their own slots entirely. Set to
    # cap each watched author's papers independently before the shared
    # maxWatchedMatches ceiling applies.
    "maxWatchedPerAuthor": None,
    "watchedAuthors": [],
}

RSS_NS = {
    "arxiv": "http://arxiv.org/schemas/atom",
    "dc": "http://purl.org/dc/elements/1.1/",
}


def log(msg: str) -> None:
    print(f"[arxiv-scanner] {msg}", file=sys.stderr)


class ClaudeOutputTooLarge(subprocess.SubprocessError):
    pass


def _kill_process_group(proc: subprocess.Popen) -> None:
    # proc.kill() only signals the direct child. claude (or the shell/tool
    # wrapper a `claude` shim might be) can have children of its own, which
    # would otherwise be orphaned and keep running past the timeout/cap that
    # was supposed to stop them. start_new_session=True below puts the whole
    # tree in its own process group so this reaches all of it.
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_claude(prompt: str, timeout: float, max_bytes: int = MAX_CLAUDE_OUTPUT_CHARS) -> subprocess.CompletedProcess:
    """
    subprocess.run(["claude", ...], capture_output=True) but:

    - the max_bytes cap is enforced while reading the child's stdout/stderr
      pipes, not by truncating a string after the full output has already
      been buffered in memory — a misbehaving or compromised claude process
      gets killed the moment it crosses the cap rather than being allowed
      to keep writing.
    - stdin is written and stdout/stderr are drained concurrently in one
      non-blocking select loop, with the timeout deadline starting before
      any I/O at all. Writing the whole prompt to stdin first and only
      then starting to read stdout/stderr (subprocess.run's own approach,
      minus its internal threading) deadlocks once the prompt is bigger
      than the OS pipe buffer (~64KB — an easy bar for a batch of paper
      abstracts) and the child hasn't fully drained stdin before it starts
      writing its own output: the parent blocks on a full stdin pipe, the
      child blocks on a full stdout pipe, forever — and since the deadline
      was never started, the timeout never fires either.

    Raises ClaudeOutputTooLarge (a subprocess.SubprocessError, so existing
    `except subprocess.SubprocessError` call sites catch it without change)
    if either stream exceeds max_bytes, and subprocess.TimeoutExpired if
    the whole exchange doesn't finish within timeout seconds.

    The prompt embeds untrusted third-party text (paper titles/abstracts
    from arXiv) and this runs unattended off a systemd timer — an
    adversarial abstract could try to talk Claude into invoking a tool or
    an MCP server, subject to whatever the user has locally configured
    (permissive Bash rules, a connected MCP service, etc). --tools ""
    removes every built-in tool regardless of that config, so there's
    nothing to invoke even if the injection attempt would otherwise have
    "worked"; --disallowedTools is needed separately since --tools doesn't
    reach MCP tools. Verified empirically (--output-format stream-json,
    inspecting the system/init event) rather than assumed from the docs
    alone: with both flags, `tools` comes back [] even though a few
    claude.ai-connector MCP servers still show as "connected" in that same
    event — connection status there doesn't imply any of their tools are
    actually exposed, and none are.

    --setting-sources "" additionally drops most locally-installed skills
    from that same session (confirmed by diffing system/init's `skills`
    list with and without it) — but not `memory_paths` (CLAUDE.md/auto
    memory), which stays populated either way. --bare is the one flag
    that's documented to skip CLAUDE.md/memory too, and would be the more
    complete fix, but it also stops reading the OAuth/subscription session
    this plugin otherwise relies on (needs ANTHROPIC_API_KEY instead),
    which would break it for most users — not used here for that reason.
    The residual exposure this leaves is CLAUDE.md content shaping output
    *style*, not any tool/MCP invocation capability, which is fully closed
    above regardless.
    """
    deadline = time.monotonic() + timeout  # starts now, before any I/O
    proc = subprocess.Popen(
        ["claude", "-p", "--output-format", "text",
         "--tools", "", "--disallowedTools", "mcp__*", "--setting-sources", ""],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdin_fd, stdout_fd, stderr_fd = proc.stdin.fileno(), proc.stdout.fileno(), proc.stderr.fileno()
        for fd in (stdin_fd, stdout_fd, stderr_fd):
            os.set_blocking(fd, False)

        stdin_data = prompt.encode()
        stdin_pos = 0
        stdin_open = len(stdin_data) > 0

        sel = selectors.DefaultSelector()
        sel.register(stdout_fd, selectors.EVENT_READ, "stdout")
        sel.register(stderr_fd, selectors.EVENT_READ, "stderr")
        if stdin_open:
            sel.register(stdin_fd, selectors.EVENT_WRITE, "stdin")
        else:
            proc.stdin.close()

        chunks = {"stdout": bytearray(), "stderr": bytearray()}
        open_read = {"stdout", "stderr"}

        while open_read or stdin_open:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _kill_process_group(proc)
                raise subprocess.TimeoutExpired(proc.args, timeout)
            for key, _ in sel.select(timeout=min(remaining, 1.0)):
                name = key.data
                if name == "stdin":
                    try:
                        n = os.write(stdin_fd, stdin_data[stdin_pos:stdin_pos + 65536])
                        stdin_pos += n
                    except BlockingIOError:
                        continue
                    except BrokenPipeError:
                        n = None
                    if n is None or stdin_pos >= len(stdin_data):
                        sel.unregister(stdin_fd)
                        proc.stdin.close()
                        stdin_open = False
                    continue

                fd = stdout_fd if name == "stdout" else stderr_fd
                try:
                    chunk = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    sel.unregister(fd)
                    open_read.discard(name)
                    continue
                chunks[name].extend(chunk)
                if len(chunks[name]) > max_bytes:
                    _kill_process_group(proc)
                    raise ClaudeOutputTooLarge(f"claude {name} exceeded {max_bytes} bytes")

        returncode = proc.wait(timeout=max(0.0, deadline - time.monotonic()))
        return subprocess.CompletedProcess(
            proc.args, returncode,
            chunks["stdout"].decode(errors="replace"),
            chunks["stderr"].decode(errors="replace"),
        )
    finally:
        if proc.poll() is None:
            _kill_process_group(proc)


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def _atomic_write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Not a predictable "<name>.tmp": that name could be pre-planted as a
    # symlink, and .write_text() follows it, truncating whatever it points
    # at instead of a real temp file. mkstemp opens with O_CREAT | O_EXCL,
    # which fails rather than following an existing path (symlink or
    # otherwise), so this can only ever create a brand new file.
    fd, tmp_path = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(data, indent=2))
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def write_state(state: dict) -> None:
    _atomic_write_json(STATE_FILE, state)


def load_watched_candidates() -> list[dict]:
    if WATCHED_CANDIDATES_FILE.exists():
        try:
            data = json.loads(WATCHED_CANDIDATES_FILE.read_text())
            if isinstance(data, list):
                return data
        except (json.JSONDecodeError, OSError):
            pass
    return []


def write_watched_candidates(candidates: list[dict]) -> None:
    _atomic_write_json(WATCHED_CANDIDATES_FILE, candidates)


def prune_watched_candidates(candidates: list[dict]) -> list[dict]:
    """
    Bounds the persistent watched-author superset so a long-running
    install with many watched authors can't grow it unboundedly — capped
    by both age and count, oldest dropped first. Anything with an
    unparseable or missing published date is dropped too, rather than kept
    forever by default.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=MAX_WATCHED_CANDIDATE_AGE_DAYS)
    kept = []
    for c in candidates:
        try:
            pub = datetime.fromisoformat(c["published"].replace("Z", "+00:00"))
        except (ValueError, KeyError, AttributeError, TypeError):
            continue
        if pub >= cutoff:
            kept.append(c)
    kept.sort(key=lambda m: m["published"], reverse=True)
    return kept[:MAX_WATCHED_CANDIDATES]


def filter_watched_for_config(candidates: list[dict], watched_authors: list[str]) -> list[dict]:
    """
    The persistent superset can carry papers matched against an author
    who's since been removed from watchedAuthors. Filtered here, on every
    read, against matched_config_name — the exact watchedAuthors string
    that caused the match, not matched_author (the paper's own author-list
    spelling, which can differ) — so removing a watched author drops their
    papers from the displayed list on the very next scan, with nobody
    needing to notice and manually re-check.
    """
    watched_l = {w.strip().lower() for w in watched_authors}
    return [c for c in candidates if c.get("matched_config_name", "").strip().lower() in watched_l]


def author_cache_key(name: str, category: str) -> str:
    return f"{category.strip().lower()}::{name.strip().lower()}"


def load_author_cache() -> dict:
    if AUTHOR_CACHE_FILE.exists():
        try:
            data = json.loads(AUTHOR_CACHE_FILE.read_text())
            if isinstance(data, dict):
                return data
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def write_author_cache(cache: dict) -> None:
    _atomic_write_json(AUTHOR_CACHE_FILE, cache)


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
    # Distinct from the two above: absent, null, or 0 all mean "no
    # per-author cap" here rather than falling back to a default number,
    # since unlimited is the actual desired default (only maxWatchedMatches
    # applies) unless the user opts into capping.
    raw_per_author = data.get("maxWatchedPerAuthor")
    if raw_per_author not in (None, ""):
        try:
            n = int(raw_per_author)
            config["maxWatchedPerAuthor"] = n if n > 0 else None
        except (TypeError, ValueError):
            pass
    if isinstance(data.get("watchedAuthors"), list):
        config["watchedAuthors"] = [a.strip() for a in data["watchedAuthors"] if isinstance(a, str) and a.strip()]
    return config


ARXIV_ID_RE = re.compile(r"(\d{4}\.\d{4,5})(?:v(\d+))?")


def canonical_arxiv_id(raw_id: str) -> tuple[str, int]:
    """
    Extracts (bare_id, version) from any of the id shapes we actually see:
    "oai:arXiv.org:2609.34213v1" (RSS feed, poll.py), "http://arxiv.org/
    abs/2609.34213v1" (Atom API, check-authors.py), etc. The same paper
    turning up via both code paths — one on today's RSS scan, the other
    via check-authors.py's on-demand backfill — used to show up twice in
    watched_matches, keyed on these differing raw strings even though
    they're the same paper. Falls back to (raw_id, 0) for anything that
    doesn't match, so an unrecognized id still gets a stable, if unmerged,
    key rather than crashing.
    """
    m = ARXIV_ID_RE.search(raw_id)
    if not m:
        return raw_id, 0
    return m.group(1), int(m.group(2) or 0)


def merge_watched_matches(existing: list[dict], new: list[dict]) -> list[dict]:
    """
    Combines watched-author entries from two batches (e.g. state.json's
    existing watched_matches plus a fresh batch from either poll.py's daily
    scan or check-authors.py's backfill), collapsing anything that's the
    same underlying arXiv paper — regardless of which id format or which
    revision it was found under — into one entry: whichever carries the
    highest version number. A v2 replaces a previously-stored v1 outright
    rather than sitting alongside it.
    """
    by_base: dict[str, dict] = {}
    for m in existing + new:
        base, version = canonical_arxiv_id(m["id"])
        current = by_base.get(base)
        if current is None or version >= canonical_arxiv_id(current["id"])[1]:
            by_base[base] = m
    return list(by_base.values())


def cap_per_author(matches: list[dict], max_per_author: int | None) -> list[dict]:
    """
    Keeps at most max_per_author most-recent papers per matched_author,
    applied before the shared maxWatchedMatches ceiling. Without this, that
    ceiling is a global top-N-most-recent-overall across every watched
    author combined — with several authors watched, whoever happens to
    publish most often or most recently crowds the rest out of their own
    slots entirely, rather than each author getting guaranteed visibility.
    None (the default) or 0 disables this and returns matches unchanged.
    """
    if not max_per_author:
        return matches
    by_author: dict[str, list[dict]] = {}
    for m in matches:
        by_author.setdefault(m.get("matched_author", ""), []).append(m)
    kept = []
    for papers in by_author.values():
        papers.sort(key=lambda m: m["published"], reverse=True)
        kept.extend(papers[:max_per_author])
    return kept


_LATEX_ACCENTS = {
    "'": {"a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý",
          "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú", "Y": "Ý",
          "n": "ń", "N": "Ń", "c": "ć", "C": "Ć", "s": "ś", "S": "Ś",
          "z": "ź", "Z": "Ź", "l": "ĺ", "L": "Ĺ", "r": "ŕ", "R": "Ŕ"},
    "`": {"a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù",
          "A": "À", "E": "È", "I": "Ì", "O": "Ò", "U": "Ù"},
    '"': {"a": "ä", "e": "ë", "i": "ï", "o": "ö", "u": "ü", "y": "ÿ",
          "A": "Ä", "E": "Ë", "I": "Ï", "O": "Ö", "U": "Ü"},
    "^": {"a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û",
          "A": "Â", "E": "Ê", "I": "Î", "O": "Ô", "U": "Û"},
    "~": {"a": "ã", "n": "ñ", "o": "õ", "A": "Ã", "N": "Ñ", "O": "Õ"},
    "c": {"c": "ç", "C": "Ç", "s": "ş", "S": "Ş"},
    "v": {"c": "č", "C": "Č", "s": "š", "S": "Š", "z": "ž", "Z": "Ž",
          "e": "ě", "E": "Ě", "r": "ř", "R": "Ř", "n": "ň", "N": "Ň"},
    "u": {"a": "ă", "A": "Ă", "g": "ğ", "G": "Ğ"},
    "H": {"o": "ő", "O": "Ő", "u": "ű", "U": "Ű"},
    "k": {"a": "ą", "A": "Ą", "e": "ę", "E": "Ę"},
}
_LATEX_ACCENT_RE = re.compile(r"\\(['`\"^~cvuHk])\{?([A-Za-z])\}?")


def normalize_latex_accents(text: str) -> str:
    """
    Some arXiv metadata — title fields especially, via the RSS feed —
    ships with a raw, un-rendered LaTeX accent macro instead of the actual
    character, e.g. "R\\'enyi" instead of "Rényi". That's an arXiv/
    submission-metadata quality quirk (confirmed: the Atom API's title for
    the same paper is properly decoded), not something specific to one
    paper, so it's worth a best-effort general fix rather than a one-off
    patch. Idempotent — already-correct Unicode text has nothing to match.
    """
    if not text:
        return text
    return _LATEX_ACCENT_RE.sub(
        lambda m: _LATEX_ACCENTS.get(m.group(1), {}).get(m.group(2), m.group(0)),
        text,
    )


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
        title = normalize_latex_accents(" ".join((item.findtext("title", default="") or "").split()))
        description = item.findtext("description", default="") or ""
        abstract = normalize_latex_accents(re.sub(r"^.*?Abstract:\s*", "", description, flags=re.DOTALL).strip())
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
                        # The exact watchedAuthors config string that caused
                        # this match (vs matched_author above, the paper's
                        # own spelling) — used to re-filter the persistent
                        # candidate superset against the *current* config on
                        # every scan, so removing a watched author actually
                        # drops their papers instead of them lingering.
                        "matched_config_name": name,
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
        result = run_claude(build_summary_prompt(papers), timeout=120)
        if result.returncode == 0:
            match = re.search(r"\[.*\]", result.stdout.strip(), re.DOTALL)
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
        result = run_claude(prompt, timeout=180)
    except (subprocess.SubprocessError, OSError) as e:
        log(f"claude invocation failed: {e}")
        return []

    if result.returncode != 0:
        log(f"claude exited {result.returncode}: {result.stderr[:400]}")
        return []

    text = result.stdout.strip()
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


STALE_SCAN_HOURS = 24


def is_scan_stale(state: dict, max_hours: int = STALE_SCAN_HOURS) -> bool:
    """
    True if state.json has no updated_at (never scanned) or it's older
    than max_hours. Used only by the startup catch-up path (--if-stale) —
    a laptop that's off through a scheduled OnCalendar run relies on the
    daily timer's own Persistent=true to fire that run as soon as the
    user's systemd instance is active again, which should cover this, but
    is one more moving part (session lingering, stamp-file bookkeeping)
    than a plugin author can fully vouch for sight unseen. This makes the
    same outcome (an overdue scan actually happens) independently
    checkable and debuggable from poll.py's own logs, regardless of
    whether systemd's own catch-up fired.
    """
    raw = state.get("updated_at")
    if not raw:
        return True
    try:
        last = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return True
    return datetime.now(timezone.utc) - last > timedelta(hours=max_hours)


def main(only_if_stale: bool = False) -> None:
    prev = load_state()
    notified_ids = prev.get("_notified_ids", [])
    config = load_config()

    if only_if_stale and not is_scan_stale(prev):
        log(f"last scan was under {STALE_SCAN_HOURS}h ago — skipping startup catch-up scan")
        return

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

    # Today's hits merge into the durable superset (never directly into the
    # displayed list) — merge_watched_matches collapses the same paper found
    # via both this scan and check-authors.py's backfill (different id
    # formats for an identical paper) and lets a newer revision replace an
    # older one instead of both showing up; prune_watched_candidates bounds
    # the superset by age/count so it can't grow unboundedly over time.
    watched_candidates = merge_watched_matches(load_watched_candidates(), todays_watched)
    watched_candidates = prune_watched_candidates(watched_candidates)
    write_watched_candidates(watched_candidates)

    # The displayed watched_matches is a fresh VIEW recomputed from that
    # superset on *every* scan — filtered against whichever authors are
    # currently configured (so removing one drops their papers immediately,
    # not just on the next manual re-check) and re-capped fresh (so a
    # raised cap or a freed-up per-author slot fills back in on its own).
    watched_matches = filter_watched_for_config(watched_candidates, config["watchedAuthors"])
    watched_matches = cap_per_author(watched_matches, config.get("maxWatchedPerAuthor"))
    watched_matches = sorted(watched_matches, key=lambda m: m["published"], reverse=True)
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
    main(only_if_stale="--if-stale" in sys.argv[1:])
