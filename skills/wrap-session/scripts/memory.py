#!/usr/bin/env python3
"""memory.py — deterministic helper for the /wrap-session skill.

Subcommands
  preflight              repo, Qdrant health, collection, counts, survey sources, workdir
  check  <file.json>     schema + secret scan + indexed-prefix preview + nearest neighbours
  store  <file.json>     re-validate, embed, upsert, verify, delete superseded, receipt, marker

Run through memory.sh, which picks the interpreter of the mcp-server-qdrant uv tool
install: it has fastembed and the cached MiniLM model, the same embedder the
claude-memory MCP server uses. Vectors written here match MCP-written ones.

Why a script: the MCP find tool returns no point IDs and cannot filter by repo, so
dedup was ID-less and supersession was text-only; the MCP store tool can strand
metadata when a tool call is serialized wrong; and the embedder truncates at 128
tokens, which nothing used to surface. All three are handled here.

Exit codes: 0 ok · 2 Qdrant/collection problem · 3 embedder unavailable
            4 secret found · 5 schema error · 6 duplicate not superseded
            7 receipt exists (already stored) · 8 post-store verification failed
"""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333").rstrip("/")
COLLECTION = os.environ.get("COLLECTION_NAME", "claude-memory")
MODEL = os.environ.get("EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
CACHE_DIR = os.path.expanduser(os.environ.get("FASTEMBED_CACHE_PATH", "~/.cache/fastembed"))
MARKER_DIR = os.environ.get("CLAUDE_MEMORY_MARKER_DIR", "/tmp")
TEST_MODE = os.environ.get("WRAP_SESSION_TEST") == "1"
MAX_TOKENS = 128  # fastembed's MiniLM tokenizer max_length (measured, see README)

CATEGORIES = ("decision", "gotcha", "lesson", "integration", "context", "session-summary")
ALLOWED_KEYS = {"repo", "topic", "category", "date", "related_repos", "pr", "supersedes"}
LIST_KEYS = ("related_repos", "pr", "supersedes")
TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,60}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DUPLICATE = 0.90
OVERLAP = 0.70

EXIT_QDRANT, EXIT_EMBED, EXIT_SECRET, EXIT_SCHEMA, EXIT_DUP, EXIT_RECEIPT, EXIT_VERIFY = 2, 3, 4, 5, 6, 7, 8

# Same shapes the v1 skill listed in prose; now applied deterministically.
SECRET_PATTERNS = [
    ("openai-style key", re.compile(r"\bsk-[A-Za-z0-9_-]{16,}")),
    ("stripe key", re.compile(r"\bpk_(?:live|test)_[A-Za-z0-9]{10,}")),
    ("slack token", re.compile(r"\bxox[bpa]-[A-Za-z0-9-]{10,}")),
    ("github token", re.compile(r"\bgh[ps]_[A-Za-z0-9]{20,}")),
    ("gitlab token", re.compile(r"\bglpat-[A-Za-z0-9_-]{16,}")),
    ("aws access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("google api key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("bearer token", re.compile(r"\bBearer\s+[A-Za-z0-9._-]{16,}")),
    ("authorization header", re.compile(r"\bAuthorization:\s*\S{8,}")),
    ("basic auth blob", re.compile(r"\bBasic\s+[A-Za-z0-9+/=]{20,}")),
    ("credential assignment",
     re.compile(r"(?i)\b(?:password|passwd|token|secret|api[_-]?key|apikey)\s*[=:]\s*['\"]?(?![<$\{]|REDACTED)[^\s'\"]{6,}")),
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("url with credentials", re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s@/]+@")),
]


# ─── Qdrant HTTP ─────────────────────────────────────────────────────────────

class QdrantError(Exception):
    pass


def q(method, path, body=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(QDRANT_URL + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise QdrantError(f"{method} {path} -> HTTP {e.code}: {e.read()[:300].decode(errors='replace')}")
    except urllib.error.URLError as e:
        raise QdrantError(f"{method} {path} -> {e.reason}")


def healthz():
    try:
        urllib.request.urlopen(QDRANT_URL + "/healthz", timeout=5).read()
        return True
    except Exception:
        return False


def collection_info():
    """Returns (ok, vector_name, points_count, error)."""
    try:
        res = q("GET", f"/collections/{COLLECTION}")["result"]
    except QdrantError as e:
        return False, None, 0, str(e)
    vectors = res["config"]["params"]["vectors"]
    name = next(iter(vectors)) if isinstance(vectors, dict) and vectors else None
    return True, name, res.get("points_count", 0), None


def count(filter_):
    return q("POST", f"/collections/{COLLECTION}/points/count",
             {"filter": filter_, "exact": True})["result"]["count"]


def repo_filter(repo, negate=False):
    cond = {"key": "metadata.repo", "match": {"value": repo}}
    return {"must_not": [cond]} if negate else {"must": [cond]}


def search(vector_name, vec, filter_, limit):
    return q("POST", f"/collections/{COLLECTION}/points/search",
             {"vector": {"name": vector_name, "vector": vec}, "filter": filter_,
              "limit": limit, "with_payload": True})["result"]


def retrieve(point_id):
    try:
        return q("GET", f"/collections/{COLLECTION}/points/{point_id}")["result"]
    except QdrantError as e:
        if "HTTP 404" in str(e):
            return None
        raise


ORPHAN_FILTER = {"should": [
    {"is_null": {"key": "metadata"}},
    {"is_empty": {"key": "metadata.repo"}},
    {"is_empty": {"key": "metadata.topic"}},
]}


def orphan_sweep():
    """Points with null/empty metadata — the stranding bug post-qdrant-store-verify.sh guards."""
    res = q("POST", f"/collections/{COLLECTION}/points/scroll",
            {"filter": ORPHAN_FILTER, "limit": 10, "with_payload": True, "with_vector": False})
    return res["result"]["points"]


# ─── Embedding ───────────────────────────────────────────────────────────────

_model = None


def vector_name_for(model):
    # mirrors mcp_server_qdrant FastEmbedProvider.get_vector_name()
    return "fast-" + model.split("/")[-1].lower()


def embedder():
    global _model
    if _model is None:
        try:
            from fastembed import TextEmbedding  # lazy: preflight must report, not crash
        except ImportError:
            sys.stderr.write("memory.py: fastembed is not importable from this interpreter; "
                             "run switch-backend.sh enable qdrant\n")
            sys.exit(EXIT_EMBED)
        _model = TextEmbedding(MODEL, cache_dir=CACHE_DIR)
    return _model


def embed(texts):
    return [v.tolist() for v in embedder().embed(texts)]


def indexed_prefix(text):
    """What the embedder actually sees: the first MAX_TOKENS tokens."""
    try:
        tok = embedder().model.tokenizer  # tokenizers.Tokenizer, truncation already set to MAX_TOKENS
        enc = tok.encode(text)
        end = max((e for (_, e) in enc.offsets), default=0)  # char offset of the last kept token
        if end <= 0:
            raise ValueError("no offsets")
        return text[:end], end < len(text.rstrip()), False
    except Exception:
        return text[:400], len(text) > 400, True


# ─── Repo / survey sources ───────────────────────────────────────────────────

def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def detect_repo():
    """basename(dirname(git-common-dir)) — correct from worktrees, where --show-toplevel is not."""
    common = git("rev-parse", "--git-common-dir")
    if not common:
        return None
    p = Path(common)
    if not p.is_absolute():
        p = Path.cwd() / p
    return p.resolve().parent.name


def toplevel():
    top = git("rev-parse", "--show-toplevel")
    return Path(top) if top else Path.cwd()


def survey_sources(today):
    top = toplevel()
    out = {}
    cap = top / ".memsearch" / "memory" / f"{today}.md"
    if cap.is_file():
        text = cap.read_text(errors="replace")
        out["memsearch_capture"] = {"path": str(cap), "turns": len(re.findall(r"^### ", text, re.M))}
    else:
        out["memsearch_capture"] = None
    for name in ("lessons.md", "todo.md"):
        f = top / "tasks" / name
        out[f"tasks_{name.split('.')[0]}"] = str(f) if f.is_file() else None
    return out


def make_workdir():
    base = Path(os.environ.get("TMPDIR", "/tmp")) / "wrap-session"
    d = base / dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    d.mkdir(parents=True, exist_ok=True)
    return str(d)


# ─── Candidates ──────────────────────────────────────────────────────────────

def load_candidates(path):
    try:
        data = json.loads(Path(path).read_text())
    except Exception as e:
        fail(EXIT_SCHEMA, f"cannot read {path}: {e}")
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list) or not data:
        fail(EXIT_SCHEMA, f"{path}: expected a non-empty JSON list of candidates")
    return data


def validate(cand, detected_repo):
    """Returns (errors, warnings). Fills repo/date defaults in place."""
    errors, warnings = [], []
    if not isinstance(cand, dict):
        return ["candidate is not an object"], warnings
    info = cand.get("information")
    if not isinstance(info, str) or not info.strip():
        errors.append("information: missing or empty")
    md = cand.get("metadata")
    if not isinstance(md, dict):
        return errors + ["metadata: missing or not an object"], warnings
    extra = set(cand) - {"information", "metadata"}
    if extra:
        errors.append(f"unknown top-level keys: {sorted(extra)}")
    unknown = set(md) - ALLOWED_KEYS
    if unknown:
        errors.append(f"metadata: unknown keys {sorted(unknown)} (allowed: {sorted(ALLOWED_KEYS)})")
    repo = md.get("repo")
    if not repo:
        if detected_repo:
            md["repo"] = detected_repo
            warnings.append(f"repo defaulted to {detected_repo}")
        else:
            errors.append("metadata.repo: missing and no git repo detected")
    elif detected_repo and repo != detected_repo:
        warnings.append(f"repo={repo} differs from the detected repo {detected_repo} (allowed, double-check)")
    topic = md.get("topic")
    if not isinstance(topic, str) or not TOPIC_RE.match(topic):
        errors.append("metadata.topic: required, kebab-case ^[a-z0-9][a-z0-9-]{2,60}$")
    if md.get("category") not in CATEGORIES:
        errors.append(f"metadata.category: required, one of {list(CATEGORIES)}")
    date = md.get("date")
    if date is not None and not (isinstance(date, str) and DATE_RE.match(date)):
        errors.append("metadata.date: must be YYYY-MM-DD")
    for k in LIST_KEYS:
        v = md.get(k)
        if v is not None and not (isinstance(v, list) and all(isinstance(x, str) and x for x in v)):
            errors.append(f"metadata.{k}: must be a list of non-empty strings")
    return errors, warnings


def scan_secrets(text):
    hits = []
    for name, rx in SECRET_PATTERNS:
        for m in rx.finditer(text):
            s = m.group(0)
            hits.append({"pattern": name, "sample": s[:6] + "…" + f"({len(s)} chars)"})
    return hits


def neighbours(vector_name, vec, repo, limit=3):
    same = [fmt_hit(h) for h in search(vector_name, vec, repo_filter(repo), limit)]
    other = [fmt_hit(h) for h in search(vector_name, vec, repo_filter(repo, negate=True), 1)]
    return same, other


def fmt_hit(h):
    md = (h.get("payload") or {}).get("metadata") or {}
    doc = (h.get("payload") or {}).get("document") or ""
    score = round(float(h["score"]), 3)
    label = "DUPLICATE" if score >= DUPLICATE else ("OVERLAP" if score >= OVERLAP else "")
    return {"id": h["id"], "score": score, "label": label, "repo": md.get("repo"),
            "topic": md.get("topic"), "date": md.get("date"),
            "snippet": re.sub(r"\s+", " ", doc)[:160]}


def analyze(cands, detected_repo, vector_name):
    """Shared by check and store: validation, secrets, prefix preview, neighbours."""
    results = []
    for c in cands:
        errors, warnings = validate(c, detected_repo)
        info = c.get("information") if isinstance(c, dict) else None
        results.append({"errors": errors, "warnings": warnings,
                        "secrets": scan_secrets(info) if isinstance(info, str) else [],
                        "prefix": None, "truncated": False, "prefix_approx": False,
                        "same_repo": [], "cross_repo": [], "topic_points": 0, "batch_dups": []})
    valid_idx = [i for i, r in enumerate(results) if not r["errors"]]
    if not valid_idx:
        return results, {}
    texts = [cands[i]["information"] for i in valid_idx]
    vecs = embed(texts)
    for i, vec in zip(valid_idx, vecs):
        r, c = results[i], cands[i]
        md = c["metadata"]
        r["prefix"], r["truncated"], r["prefix_approx"] = indexed_prefix(c["information"])
        r["same_repo"], r["cross_repo"] = neighbours(vector_name, vec, md["repo"])
        r["topic_points"] = count({"must": [{"key": "metadata.repo", "match": {"value": md["repo"]}},
                                            {"key": "metadata.topic", "match": {"value": md["topic"]}}]})
        for pid in md.get("supersedes") or []:
            if retrieve(pid) is None:
                r["warnings"].append(f"supersedes {pid}: no such point in {COLLECTION} (store will refuse)")
    # duplicates inside the batch itself
    for a in range(len(valid_idx)):
        for b in range(a + 1, len(valid_idx)):
            s = cosine(vecs[a], vecs[b])
            if s >= DUPLICATE:
                results[valid_idx[a]]["batch_dups"].append({"other": valid_idx[b] + 1, "score": round(s, 3)})
                results[valid_idx[b]]["batch_dups"].append({"other": valid_idx[a] + 1, "score": round(s, 3)})
    return results, dict(zip(valid_idx, vecs))


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(y * y for y in b) ** 0.5
    return dot / (na * nb) if na and nb else 0.0


# ─── Output helpers ──────────────────────────────────────────────────────────

def fail(code, msg):
    sys.stderr.write(f"memory.py: {msg}\n")
    sys.exit(code)


def print_analysis(cands, results, detected_repo, header):
    print(f"{header} — {len(cands)} candidate(s), repo={detected_repo or '?'}, collection={COLLECTION}")
    for n, (c, r) in enumerate(zip(cands, results), 1):
        md = c.get("metadata") if isinstance(c, dict) else {}
        md = md if isinstance(md, dict) else {}
        info = c.get("information") if isinstance(c, dict) else ""
        info = info if isinstance(info, str) else ""
        print(f"\n[{n}] topic={md.get('topic')}  category={md.get('category')}  repo={md.get('repo')}  {len(info):,} chars")
        for e in r["errors"]:
            print(f"    SCHEMA ERROR: {e}")
        for w in r["warnings"]:
            print(f"    warning: {w}")
        for s in r["secrets"]:
            print(f"    SECRET: {s['pattern']} {s['sample']}")
        if r["errors"]:
            continue
        flag =" (TRUNCATED — only this part is searchable)" if r["truncated"] else ""
        approx = " [approximate]" if r["prefix_approx"] else ""
        print(f"    indexed prefix{approx}{flag}:\n      \"{r['prefix']}\"")
        if r["same_repo"]:
            print(f"    nearest in repo {md.get('repo')}:")
            for h in r["same_repo"]:
                print(f"      {h['score']:.3f} {h['label']:<9} {h['id']}  {h['topic']}  {h['date'] or '-'}\n"
                      f"            \"{h['snippet']}\"")
        else:
            print(f"    nearest in repo {md.get('repo')}: none")
        for h in r["cross_repo"]:
            print(f"    nearest elsewhere: {h['score']:.3f} {h['label']:<9} {h['id']}  {h['repo']}/{h['topic']}")
        if r["topic_points"]:
            print(f"    topic already has {r['topic_points']} point(s) in this repo — reuse it only if superseding")
        for d in r["batch_dups"]:
            print(f"    DUPLICATE within this file: candidate [{d['other']}] ({d['score']:.3f})")


def summarize(results):
    return {
        "schema_errors": sum(len(r["errors"]) for r in results),
        "secrets": sum(len(r["secrets"]) for r in results),
        "duplicates": sum(1 for r in results if any(h["label"] == "DUPLICATE" for h in r["same_repo"] + r["cross_repo"]) or r["batch_dups"]),
        "overlaps": sum(1 for r in results if any(h["label"] == "OVERLAP" for h in r["same_repo"])),
    }


# ─── Subcommands ─────────────────────────────────────────────────────────────

def cmd_preflight(args):
    today = dt.date.today().isoformat()
    out = {"date": today, "cwd": os.getcwd(), "repo": detect_repo(), "qdrant_url": QDRANT_URL,
           "collection": COLLECTION, "interpreter": sys.executable}
    out["qdrant_ok"] = healthz()
    if not out["qdrant_ok"]:
        emit(args, out)
        fail(EXIT_QDRANT, "Qdrant is down — memories cannot be stored. memsearch (per-repo) has still "
                          "captured locally. Run ~/github/claude-thoughts/switch-backend.sh status or restart "
                          "the container, then re-invoke /wrap-session.")
    ok, vname, points, err = collection_info()
    out.update({"collection_ok": ok, "vector_name": vname, "points_total": points})
    if not ok:
        emit(args, out)
        fail(EXIT_QDRANT, f"Collection `{COLLECTION}` does not exist on the Qdrant instance ({err}). Check the "
                          "claude-memory MCP server config or restore from ~/qdrant-dumps/.")
    expected = vector_name_for(MODEL)
    out["vector_name_ok"] = vname == expected
    if not out["vector_name_ok"]:
        emit(args, out)
        fail(EXIT_QDRANT, f"collection vector is `{vname}`, expected `{expected}` for {MODEL}; refusing to write "
                          "vectors from a different model")
    out["points_repo"] = count(repo_filter(out["repo"])) if out["repo"] else None
    try:
        import time
        t0 = time.time()
        embedder()
        out["embedder_ms"] = int((time.time() - t0) * 1000)
    except SystemExit:
        raise
    out.update(survey_sources(today))
    out["workdir"] = make_workdir()
    out["session_id"] = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if args.json:
        print(json.dumps(out, indent=2))
        return
    cap = out["memsearch_capture"]
    print(f"wrap-session preflight — {today}")
    print(f"  repo:        {out['repo'] or '(not a git repo: pass repo in each candidate)'}")
    print(f"  qdrant:      ok ({QDRANT_URL}), collection {COLLECTION} ok, vector {vname}, "
          f"{points:,} points total, {out['points_repo'] if out['points_repo'] is not None else '-'} for this repo")
    print(f"  embedder:    {MODEL} ready in {out['embedder_ms']} ms (indexes only the first {MAX_TOKENS} tokens ≈ 350 chars)")
    print(f"  memsearch:   {cap['path'] + ' (' + str(cap['turns']) + ' turns today)' if cap else 'no capture for today'}")
    print(f"  tasks:       lessons={out['tasks_lessons'] or '-'}  todo={out['tasks_todo'] or '-'}")
    print(f"  workdir:     {out['workdir']}")
    print(f"  next:        write {out['workdir']}/candidates.json, then: memory.sh check <that file>")


def emit(args, out):
    if args.json:
        print(json.dumps(out, indent=2))


def cmd_check(args):
    guard_collection()
    detected = detect_repo()
    ok, vname, _, err = collection_info()
    if not ok:
        fail(EXIT_QDRANT, f"collection {COLLECTION}: {err}")
    cands = load_candidates(args.file)
    results, _ = analyze(cands, detected, vname)
    s = summarize(results)
    if args.json:
        print(json.dumps({"candidates": cands, "results": results, "summary": s}, indent=2))
    else:
        print_analysis(cands, results, detected, "wrap-session check")
        print(f"\nSummary: {s['schema_errors']} schema error(s), {s['secrets']} secret(s), "
              f"{s['duplicates']} DUPLICATE, {s['overlaps']} OVERLAP")
        if s["schema_errors"] or s["secrets"]:
            print("→ fix the file and re-run check")
        elif s["duplicates"]:
            print("→ drop each DUPLICATE or add its id to that candidate's metadata.supersedes, then run store")
        else:
            print("→ for each OVERLAP decide: supersede (add id to metadata.supersedes, reuse the topic) or keep both; then run store")
    if s["secrets"]:
        sys.exit(EXIT_SECRET)
    if s["schema_errors"]:
        sys.exit(EXIT_SCHEMA)


def guard_collection():
    if TEST_MODE and COLLECTION == "claude-memory":
        fail(EXIT_QDRANT, "WRAP_SESSION_TEST=1 refuses to touch the live claude-memory collection")


def cmd_store(args):
    guard_collection()
    path = Path(args.file)
    receipt = path.with_suffix(".receipt.json")
    if receipt.exists():
        fail(EXIT_RECEIPT, f"{receipt} exists — this file was already stored. Write a new candidates file for new items.")
    detected = detect_repo()
    ok, vname, _, err = collection_info()
    if not ok:
        fail(EXIT_QDRANT, f"collection {COLLECTION}: {err}")
    cands = load_candidates(path)
    results, vecs = analyze(cands, detected, vname)
    s = summarize(results)
    problems = []
    if s["schema_errors"]:
        problems.append((EXIT_SCHEMA, "schema errors"))
    if s["secrets"]:
        problems.append((EXIT_SECRET, "secret-shaped text (redact it as <REDACTED> or drop the candidate)"))
    for n, (c, r) in enumerate(zip(cands, results), 1):
        if r["errors"]:
            continue
        sup = set(c["metadata"].get("supersedes") or [])
        dups = [h for h in r["same_repo"] + r["cross_repo"] if h["label"] == "DUPLICATE" and h["id"] not in sup]
        if dups or r["batch_dups"]:
            problems.append((EXIT_DUP, f"candidate [{n}] duplicates existing point(s) "
                                       f"{[h['id'] for h in dups]} or another candidate; drop it or list the id in metadata.supersedes"))
        for pid in sup:
            if retrieve(pid) is None:
                problems.append((EXIT_SCHEMA, f"candidate [{n}] supersedes {pid}, which does not exist in {COLLECTION}"))
    if problems:
        print_analysis(cands, results, detected, "wrap-session store (refused)")
        print()
        for _, msg in problems:
            print(f"REFUSED: {msg}")
        sys.exit(problems[0][0])

    today = dt.date.today().isoformat()
    stored, deleted = [], []
    for n, (c, r) in enumerate(zip(cands, results), 1):
        md = c["metadata"]
        md.setdefault("date", today)
        pid = str(uuid.uuid4())
        q("PUT", f"/collections/{COLLECTION}/points?wait=true",
          {"points": [{"id": pid, "vector": {vname: vecs[n - 1]},
                       "payload": {"document": c["information"], "metadata": md}}]})
        back = retrieve(pid)
        bmd = ((back or {}).get("payload") or {}).get("metadata") or {}
        if not back or bmd.get("repo") != md["repo"] or bmd.get("topic") != md["topic"] \
                or (back.get("payload") or {}).get("document") != c["information"]:
            fail(EXIT_VERIFY, f"point {pid} ({md['topic']}) did not read back with its metadata/document — "
                              f"inspect: curl -s {QDRANT_URL}/collections/{COLLECTION}/points/{pid}")
        stored.append({"id": pid, "topic": md["topic"], "repo": md["repo"], "category": md["category"]})
        for old in md.get("supersedes") or []:
            q("POST", f"/collections/{COLLECTION}/points/delete?wait=true", {"points": [old]})
            if retrieve(old) is not None:
                fail(EXIT_VERIFY, f"superseded point {old} still exists after delete")
            deleted.append({"id": old, "superseded_by": pid})
    orphans = orphan_sweep()
    receipt.write_text(json.dumps({"collection": COLLECTION, "at": dt.datetime.now().isoformat(timespec="seconds"),
                                   "stored": stored, "deleted": deleted}, indent=2))
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if sid:
        try:
            Path(MARKER_DIR, f".claude-memory-stored-{sid}").touch()
        except OSError:
            pass
    if args.json:
        print(json.dumps({"stored": stored, "deleted": deleted, "orphans": orphans, "receipt": str(receipt)}, indent=2))
    else:
        width = max([len(x["topic"]) for x in stored] + [20])
        print(f"Stored to Qdrant (collection: {COLLECTION})")
        print("─" * (width + 40))
        print(f"{len(stored)} stored  |  {len(deleted)} superseded point(s) deleted")
        print("─" * (width + 40))
        for x in stored:
            print(f"✓ {x['topic']:<{width}}  {x['category']:<15} {x['id']}")
        for d in deleted:
            print(f"⌫ deleted {d['id']}  (superseded by {d['superseded_by']})")
        print("─" * (width + 40))
        print(f"receipt: {receipt}")
    if orphans:
        print(f"\nVERIFICATION FAILED: {len(orphans)} point(s) in {COLLECTION} have null/empty metadata:")
        for p in orphans:
            print(f"  - {p['id']}: {((p.get('payload') or {}).get('document') or '')[:100]!r}")
        print("Repair: delete + re-store while the text is in context (see ~/.claude/hooks/post-qdrant-store-verify.sh)")
        sys.exit(EXIT_VERIFY)


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("preflight").set_defaults(fn=cmd_preflight)
    p = sub.add_parser("check")
    p.add_argument("file")
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("store")
    p.add_argument("file")
    p.set_defaults(fn=cmd_store)
    args = ap.parse_args()
    try:
        args.fn(args)
    except QdrantError as e:
        fail(EXIT_QDRANT, str(e))


if __name__ == "__main__":
    main()
