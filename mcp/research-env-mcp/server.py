#!/usr/bin/env python3
"""research-env-v1 stdio MCP server — thin shim for the Rockie research action space.

A dependency-free MCP server (JSON-RPC 2.0 over stdio, framed by Content-Length
headers per the MCP/LSP wire format). It:

  1. Loads the 9 tool schemas from the contract manifest (CANONICAL source) at
     ../../contract/research-env-v1/ relative to this file (overridable via
     RESEARCH_ENV_CONTRACT_DIR), hardcoding NOTHING about the tool set except dispatch.
  2. Advertises them via MCP `tools/list`.
  3. Dispatches `tools/call`.

Side-effect policy:
  - REAL local-FS, sandboxed to a workspace dir (RESEARCH_ENV_WORKSPACE, default ./workspace):
        read_file, list_files, write_file, run_command
  - REAL Rockie backend (device-auth via rockie_auth; $ROCKIELAB_API_URL):
        submit_job, get_job
  - REAL web (stdlib urllib, NO backend dependency, keyless by default so it
    works for free/local/BYOK users out of the box):
        web_search  — DuckDuckGo HTML by default; a BYO SEARCH_API_KEY provider
                      (tavily/brave/serper) overrides it for higher quality.
        fetch_url   — plain HTTP(S) GET → readable text, SSRF-guarded (blocks
                      private/loopback/link-local/metadata ranges on every hop)
                      because the same tool runs on platform tenant machines.
  - finish: terminal tool, echoes the result.

Result-string format (contract README § Result-string format):
  - success: raw text, or pretty-printed JSON (2-space) for structured tools
  - error:   {"error":{"code":<stable_string>,"message":<prose>}}  as a text block

submit_job/get_job are wired (Slice B) against the same device-flow + jobs API
the shipped @rockielab/cli uses. web_search/fetch_url run directly from this
server (no Rockie backend), keeping local ≡ platform: the identical tool code
executes in both places.
"""
import html
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import rockie_auth

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "research-env-v1"
SERVER_VERSION = "0.1.0"

CONTRACT_DIR = Path(
    os.environ.get(
        "RESEARCH_ENV_CONTRACT_DIR",
        # Default: the contract/ dir at the repo root, relative to this file
        # (mcp/research-env-mcp/server.py -> ../../contract/research-env-v1).
        Path(__file__).resolve().parent.parent.parent / "contract" / "research-env-v1",
    )
).expanduser()
WORKSPACE = Path(os.environ.get("RESEARCH_ENV_WORKSPACE", "./workspace")).expanduser().resolve()


def log(msg):
    print(f"[research-env-mcp] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Contract loading — the tool SET comes entirely from the manifest + schemas.
# ---------------------------------------------------------------------------
def load_tools():
    manifest = json.loads((CONTRACT_DIR / "manifest.json").read_text())
    tools = []
    for entry in manifest["tools"]:
        schema = json.loads((CONTRACT_DIR / entry["schema"]).read_text())
        tools.append(
            {
                "name": schema["name"],
                "description": schema.get("description", ""),
                "inputSchema": schema["inputSchema"],
            }
        )
    return tools


TOOLS = load_tools()


# ---------------------------------------------------------------------------
# Workspace sandbox helpers
# ---------------------------------------------------------------------------
def _safe_path(rel: str) -> Path:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    p = (WORKSPACE / rel).resolve()
    if p != WORKSPACE and WORKSPACE not in p.parents:
        raise ValueError(f"path escapes workspace sandbox: {rel}")
    return p


class ToolError(Exception):
    def __init__(self, code, message):
        self.code = code
        self.message = message


# ---------------------------------------------------------------------------
# Tool implementations (real FS for 4, deterministic stubs for 4, terminal finish)
# ---------------------------------------------------------------------------
def t_read_file(args):
    p = _safe_path(args["path"])
    if not p.is_file():
        raise ToolError("tool_error", f"not a file: {args['path']}")
    return p.read_text()


def t_list_files(args):
    base = _safe_path(args.get("path", "."))
    if not base.exists():
        raise ToolError("tool_error", f"no such path: {args.get('path', '.')}")
    if base.is_file():
        return str(base.relative_to(WORKSPACE))
    out = []
    for f in sorted(base.rglob("*")):
        if f.is_file():
            out.append(str(f.relative_to(WORKSPACE)))
    return "\n".join(out) if out else "(empty)"


def t_write_file(args):
    p = _safe_path(args["path"])
    p.parent.mkdir(parents=True, exist_ok=True)
    content = args.get("content", "")
    p.write_text(content)
    return f"wrote {args['path']} ({len(content.encode('utf-8'))} bytes)"


# Generous, EXPLICIT per-stream output cap. Big enough for normal eval output;
# when hit, the result says so loudly (no silent truncation — see #qc-2026-06-20).
RUN_COMMAND_MAX_STREAM_BYTES = 1_000_000


def _decode_stream(raw: bytes) -> tuple[str, bool]:
    """Faithfully decode a captured stream to text, never raising.

    Decodes as UTF-8 with errors="replace" so non-UTF-8 / binary bytes (common
    from a crashing native program) become U+FFFD rather than discarding the
    ENTIRE stream via an uncaught UnicodeDecodeError. Applies the explicit byte
    cap and reports it. Returns (text, truncated)."""
    truncated = len(raw) > RUN_COMMAND_MAX_STREAM_BYTES
    if truncated:
        raw = raw[:RUN_COMMAND_MAX_STREAM_BYTES]
    return raw.decode("utf-8", errors="replace"), truncated


def t_run_command(args):
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    timeout = int(args.get("timeout_sec", 120))
    # capture_output WITHOUT text= so we get raw bytes and decode ourselves —
    # text=True would raise UnicodeDecodeError on any non-UTF-8 byte and the
    # generic handler would then drop ALL stdout/stderr + the exit code.
    try:
        r = subprocess.run(
            args["command"], shell=True, cwd=str(WORKSPACE),
            capture_output=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as e:
        # Surface whatever the command produced before the timeout — a partial
        # result is far more useful than just "timed out".
        partial = []
        for label, raw in (("stdout", e.stdout), ("stderr", e.stderr)):
            if raw:
                txt, trunc = _decode_stream(raw)
                partial.append(f"[partial {label}{' — TRUNCATED' if trunc else ''}]\n{txt}")
        joined = ("\n" + "\n".join(partial)) if partial else ""
        raise ToolError("tool_error", f"command timed out after {timeout}s{joined}")

    out, out_trunc = _decode_stream(r.stdout or b"")
    err, err_trunc = _decode_stream(r.stderr or b"")
    parts = []
    if out:
        parts.append(out if out.endswith("\n") else out + "\n")
    if out_trunc:
        parts.append(f"[stdout TRUNCATED at {RUN_COMMAND_MAX_STREAM_BYTES} bytes]\n")
    if err:
        parts.append("[stderr]\n")
        parts.append(err if err.endswith("\n") else err + "\n")
    if err_trunc:
        parts.append(f"[stderr TRUNCATED at {RUN_COMMAND_MAX_STREAM_BYTES} bytes]\n")
    parts.append(f"[exit {r.returncode}]")
    return "".join(parts)


# ---------------------------------------------------------------------------
# Web tools (stdlib only). web_search is keyless by default (DuckDuckGo HTML),
# fetch_url is SSRF-guarded. The same code runs locally and on tenant machines.
# ---------------------------------------------------------------------------
# Pretend to be a normal browser; DDG's HTML endpoint 403s an empty UA.
_UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")
HTTP_TIMEOUT_SEC = int(os.environ.get("WEB_TOOL_TIMEOUT_SEC", "20"))
FETCH_MAX_BYTES = int(os.environ.get("FETCH_URL_MAX_BYTES", str(2_000_000)))
FETCH_MAX_REDIRECTS = 5


def _http_get(url: str, *, headers=None) -> tuple[bytes, str, str]:
    """GET a URL with NO redirect following. Returns (body, final_url, content_type)."""
    req = urllib.request.Request(url, headers={"User-Agent": _UA, **(headers or {})})
    opener = urllib.request.build_opener(_NoRedirect())
    try:
        resp = opener.open(req, timeout=HTTP_TIMEOUT_SEC)
    except urllib.error.HTTPError as e:
        # 3xx surfaces here because redirects are disabled — let the caller decide.
        if e.code in (301, 302, 303, 307, 308):
            return b"", e.headers.get("Location", ""), str(e.code)
        raise ToolError("tool_error", f"HTTP {e.code} for {url}")
    except urllib.error.URLError as e:
        raise ToolError("tool_error", f"could not fetch {url}: {e.reason}")
    body = resp.read(FETCH_MAX_BYTES + 1)
    return body, resp.geturl(), resp.headers.get("Content-Type", "")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None  # raise the 3xx as an HTTPError instead of auto-following


# --- SSRF guard -----------------------------------------------------------
def _assert_public_url(url: str) -> None:
    """Reject non-http(s) schemes and any host that resolves to a private,
    loopback, link-local, or cloud-metadata address. Called on EVERY redirect hop."""
    parts = urllib.parse.urlparse(url)
    if parts.scheme not in ("http", "https"):
        raise ToolError("tool_error", f"refused non-http(s) scheme: {parts.scheme!r}")
    host = parts.hostname
    if not host:
        raise ToolError("tool_error", f"no host in url: {url!r}")
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as e:
        raise ToolError("tool_error", f"could not resolve host {host!r}: {e}")
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_reserved or ip.is_multicast or ip.is_unspecified):
            raise ToolError(
                "tool_error",
                f"refused fetch to non-public address {ip} (host {host!r})",
            )


# --- HTML → text ----------------------------------------------------------
_TAG_DROP = re.compile(r"<(script|style|noscript)[^>]*>.*?</\1>", re.S | re.I)
_TAG_ANY = re.compile(r"<[^>]+>")
_WS = re.compile(r"[ \t]*\n[ \t]*(?:\n[ \t]*)+")


def _html_to_text(raw: str) -> str:
    txt = _TAG_DROP.sub(" ", raw)
    txt = re.sub(r"<br\s*/?>", "\n", txt, flags=re.I)
    txt = re.sub(r"</(p|div|li|h[1-6]|tr)>", "\n", txt, flags=re.I)
    txt = _TAG_ANY.sub("", txt)
    txt = html.unescape(txt)
    txt = "\n".join(line.strip() for line in txt.splitlines())
    return _WS.sub("\n\n", txt).strip()


# --- web_search -----------------------------------------------------------
# DDG's lite HTML serves <a class="result-link">title</a> + a result-snippet div.
_DDG_RESULT = re.compile(
    r'<a[^>]+class="result-link"[^>]+href="(?P<url>[^"]+)"[^>]*>(?P<title>.*?)</a>'
    r'.*?<td[^>]+class="result-snippet"[^>]*>(?P<snip>.*?)</td>',
    re.S | re.I,
)
# The html.duckduckgo.com layout: <a class="result__a" href=...>title</a> + result__snippet
_DDG_RESULT_HTML = re.compile(
    r'<a[^>]+class="result__a"[^>]+href="(?P<url>[^"]+)"[^>]*>(?P<title>.*?)</a>'
    r'.*?class="result__snippet"[^>]*>(?P<snip>.*?)</(?:a|div)>',
    re.S | re.I,
)


def _strip(s: str) -> str:
    return _html_to_text(s).replace("\n", " ").strip()


def _ddg_unwrap(href: str) -> str:
    """DDG wraps result URLs as /l/?uddg=<encoded>; unwrap to the real target."""
    if href.startswith("//"):
        href = "https:" + href
    p = urllib.parse.urlparse(href)
    if "duckduckgo.com" in (p.netloc or "") and p.path.startswith("/l/"):
        qs = urllib.parse.parse_qs(p.query)
        if "uddg" in qs:
            return qs["uddg"][0]
    return href


def _search_duckduckgo(query: str, k: int) -> list:
    data = urllib.parse.urlencode({"q": query}).encode()
    body, _, _ = _http_get_post("https://html.duckduckgo.com/html/", data)
    page = body.decode("utf-8", errors="replace")
    out = []
    for m in _DDG_RESULT_HTML.finditer(page):
        out.append({
            "title": _strip(m.group("title")),
            "url": _ddg_unwrap(m.group("url")),
            "snippet": _strip(m.group("snip")),
        })
        if len(out) >= k:
            break
    if not out and ("anomaly" in page.lower() or "blocked" in page.lower()):
        raise ToolError("rate_limited",
                        "DuckDuckGo blocked this request (rate limit); set a "
                        "BYO SEARCH_API_KEY provider for reliable search.")
    return out


def _http_get_post(url: str, data: bytes) -> tuple[bytes, str, str]:
    req = urllib.request.Request(
        url, data=data,
        headers={"User-Agent": _UA,
                 "Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SEC)
    except urllib.error.HTTPError as e:
        raise ToolError("tool_error", f"search HTTP {e.code}")
    except urllib.error.URLError as e:
        raise ToolError("tool_error", f"search request failed: {e.reason}")
    return resp.read(), resp.geturl(), resp.headers.get("Content-Type", "")


def _search_byo(query: str, k: int, key: str, provider: str) -> list:
    """Higher-quality search via a BYO key. Generic, small provider switch."""
    provider = provider.lower()
    if provider == "tavily":
        body = json.dumps({"api_key": key, "query": query, "max_results": k}).encode()
        req = urllib.request.Request(
            "https://api.tavily.com/search", data=body,
            headers={"Content-Type": "application/json"})
        results_key, mapper = "results", (
            lambda r: {"title": r.get("title", ""), "url": r.get("url", ""),
                       "snippet": r.get("content", "")})
    elif provider == "brave":
        url = "https://api.search.brave.com/res/v1/web/search?" + \
            urllib.parse.urlencode({"q": query, "count": k})
        req = urllib.request.Request(
            url, headers={"X-Subscription-Token": key, "Accept": "application/json"})
        results_key, mapper = None, None  # parsed below (nested shape)
    elif provider == "serper":
        body = json.dumps({"q": query, "num": k}).encode()
        req = urllib.request.Request(
            "https://google.serper.dev/search", data=body,
            headers={"X-API-KEY": key, "Content-Type": "application/json"})
        results_key, mapper = "organic", (
            lambda r: {"title": r.get("title", ""), "url": r.get("link", ""),
                       "snippet": r.get("snippet", "")})
    else:
        raise ToolError("tool_error", f"unknown SEARCH_PROVIDER: {provider!r}")

    try:
        resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SEC)
        payload = json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as e:
        raise ToolError("tool_error", f"{provider} search HTTP {e.code}")
    except urllib.error.URLError as e:
        raise ToolError("tool_error", f"{provider} search failed: {e.reason}")

    if provider == "brave":
        items = (payload.get("web", {}) or {}).get("results", []) or []
        return [{"title": r.get("title", ""), "url": r.get("url", ""),
                 "snippet": r.get("description", "")} for r in items[:k]]
    return [mapper(r) for r in (payload.get(results_key, []) or [])[:k]]


def t_web_search(args):
    query = args["query"]
    k = max(1, min(int(args.get("k", 10)), 25))
    key = os.environ.get("SEARCH_API_KEY", "").strip()
    if key:
        provider = os.environ.get("SEARCH_PROVIDER", "tavily").strip() or "tavily"
        results = _search_byo(query, k, key, provider)
    else:
        results = _search_duckduckgo(query, k)
    if not results:
        return json.dumps({"query": query, "results": [],
                           "note": "no results"}, indent=2)
    return json.dumps(results, indent=2)


def t_fetch_url(args):
    url = args["url"]
    for _ in range(FETCH_MAX_REDIRECTS + 1):
        _assert_public_url(url)  # re-checked on every hop (SSRF defense)
        body, final_url, ctype = _http_get(url)
        if ctype in ("301", "302", "303", "307", "308"):
            if not final_url:
                raise ToolError("tool_error", "redirect with no Location header")
            url = urllib.parse.urljoin(url, final_url)
            continue
        truncated = len(body) > FETCH_MAX_BYTES
        body = body[:FETCH_MAX_BYTES]
        text = body.decode("utf-8", errors="replace")
        if "html" in ctype.lower() or text.lstrip()[:1] == "<":
            text = _html_to_text(text)
        if truncated:
            text += (f"\n\n[truncated at {FETCH_MAX_BYTES} bytes "
                     "(FETCH_URL_MAX_BYTES)]")
        return text or "(empty response body)"
    raise ToolError("tool_error", f"too many redirects (>{FETCH_MAX_REDIRECTS})")


def _require_token():
    """Resolve the Rockie bearer or raise the contract auth_required error."""
    token = rockie_auth.get_token()
    if not token:
        raise ToolError(
            "auth_required",
            "not signed in to Rockie — run `nugget login` "
            f"(or set ${rockie_auth.TOKEN_ENV_VAR}).",
        )
    return token


def _parse_hardware(hardware: str) -> tuple[str, int]:
    """Translate a capability string to the CLI's (gpu_type, gpu_count) shape.

    The contract is the masking boundary: a *capability* string in, provider
    SKU details hidden. Examples: "8xH100" → ("H100", 8); "1xA100-80GB" →
    ("A100-80GB", 1); "cpu" → ("cpu", 0); "A100" → ("A100", 1).
    NO provider/model-identity values are embedded — this is generic parsing.
    """
    s = hardware.strip()
    if s.lower() == "cpu":
        return ("cpu", 0)
    count = 1
    gpu_type = s
    if "x" in s:
        head, _, tail = s.partition("x")
        if head.isdigit() and tail:
            count = int(head)
            gpu_type = tail
    if not gpu_type:
        raise ToolError("tool_error", f"could not parse hardware: {hardware!r}")
    return (gpu_type, count)


def _budget_ceiling_cents():
    """The hard spend gate (Goose hooks are advisory, so the ceiling lives in the
    tool). $NUGGET_BUDGET_CEILING_CENTS; unset → no ceiling."""
    raw = os.environ.get("NUGGET_BUDGET_CEILING_CENTS", "").strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        raise ToolError(
            "tool_error",
            f"NUGGET_BUDGET_CEILING_CENTS must be an integer, got {raw!r}",
        )


def t_submit_job(args):
    """Translate the capability contract → the CLI's POST /api/jobs/submit body
    (connected-ops.ts submitExperiment) and enforce the budget ceiling.

    submit body: {spec:{gpu_type,gpu_count,image?}, script, env:{}, timeout_seconds}
    submit resp: {job_id, cluster_id, state, estimated_cost_cents}
    Returns the contract shape {"handle": job_id, ...awareness fields}.
    """
    token = _require_token()
    gpu_type, gpu_count = _parse_hardware(args["hardware"])
    ceiling = _budget_ceiling_cents()

    spec = {"gpu_type": gpu_type, "gpu_count": gpu_count}
    if args.get("image"):
        spec["image"] = args["image"]
    body = {
        "spec": spec,
        "script": args["command"],
        "env": {},
        "timeout_seconds": int(args.get("timeout_sec", 3600)),
    }
    # Pre-spend budget gate: if the backend offers a dry-run/estimate, use it to
    # pre-check; the env switch keeps the contract stable if/when it lands.
    dry_run = os.environ.get("NUGGET_SUBMIT_DRY_RUN", "").strip() == "1"
    if dry_run:
        body["dry_run"] = True

    try:
        resp = rockie_auth.request_json(
            "POST", "/api/jobs/submit", body=body, token=token
        )
    except rockie_auth.AuthHttpError as e:
        code = e.code or ("auth_required" if e.status in (401, 403) else "tool_error")
        raise ToolError(code, e.message)

    est = resp.get("estimated_cost_cents")
    # Hard ceiling on the returned estimate. Without a dry-run the job is already
    # submitted, so surface a loud confirmation-required error AND the handle so
    # the caller can cancel; with a dry-run nothing was charged.
    if ceiling is not None and isinstance(est, (int, float)) and est > ceiling:
        raise ToolError(
            "budget_exceeded",
            f"estimated cost {est}c exceeds NUGGET_BUDGET_CEILING_CENTS={ceiling}c"
            + ("" if dry_run else f" — submitted job {resp.get('job_id')} "
               "may incur cost; cancel it if unintended"),
        )

    out = {"handle": resp.get("job_id")}
    if resp.get("cluster_id") is not None:
        out["cluster_id"] = resp["cluster_id"]
    if resp.get("state") is not None:
        out["state"] = resp["state"]
    if est is not None:
        out["estimated_cost_cents"] = est
    if dry_run:
        out["dry_run"] = True
    return json.dumps(out, indent=2)


# Map backend job states → contract progress (design §4.2).
_PROGRESS = {"queued": 0.0, "pending": 0.0, "running": 0.5,
             "succeeded": 1.0, "failed": 1.0, "cancelled": 1.0, "timeout": 1.0}


def t_get_job(args):
    """Poll the real job (GET /api/jobs/{id}, connected-ops.ts getJobStatus) and
    map JobView → the contract get_job shape (state/progress/metrics/logs/artifacts).
    Cost is surfaced for awareness only; billing is never computed in nugget."""
    token = _require_token()
    handle = args["handle"]
    try:
        job = rockie_auth.request_json(
            "GET", f"/api/jobs/{handle}", token=token
        )
    except rockie_auth.AuthHttpError as e:
        code = e.code or ("auth_required" if e.status in (401, 403) else "tool_error")
        raise ToolError(code, e.message)

    state = job.get("state", "unknown")
    return json.dumps(
        {
            "handle": handle,
            "state": state,
            "progress": _PROGRESS.get(str(state).lower(), 0.0),
            "metrics": {
                "cost_so_far_cents": job.get("cost_so_far_cents"),
                "cost_actual_cents": job.get("cost_actual_cents"),
            },
            "logs": job.get("last_log_line") or job.get("runpod_error") or "",
            "artifacts": [],
        },
        indent=2,
    )


def t_finish(args):
    return f"[finished] {args['result']}"


DISPATCH = {
    "read_file": t_read_file,
    "list_files": t_list_files,
    "write_file": t_write_file,
    "run_command": t_run_command,
    "web_search": t_web_search,
    "fetch_url": t_fetch_url,
    "submit_job": t_submit_job,
    "get_job": t_get_job,
    "finish": t_finish,
}


def call_tool(name, args):
    """Returns (text, is_error)."""
    fn = DISPATCH.get(name)
    if fn is None:
        return json.dumps({"error": {"code": "unknown_tool", "message": f"no such tool: {name}"}}), True
    try:
        return fn(args or {}), False
    except ToolError as e:
        return json.dumps({"error": {"code": e.code, "message": e.message}}), True
    except Exception as e:  # noqa: BLE001 — surface any impl failure in the contract envelope
        return json.dumps({"error": {"code": "tool_error", "message": str(e)}}), True


# ---------------------------------------------------------------------------
# JSON-RPC dispatch
# ---------------------------------------------------------------------------
def handle(req):
    method = req.get("method")
    rid = req.get("id")
    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": rid,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }
    if method in ("notifications/initialized", "initialized"):
        return None  # notification, no response
    if method == "ping":
        return {"jsonrpc": "2.0", "id": rid, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = req.get("params", {})
        text, is_error = call_tool(params.get("name"), params.get("arguments"))
        return {
            "jsonrpc": "2.0", "id": rid,
            "result": {"content": [{"type": "text", "text": text}], "isError": is_error},
        }
    if rid is None:
        return None  # unknown notification — ignore
    return {
        "jsonrpc": "2.0", "id": rid,
        "error": {"code": -32601, "message": f"method not found: {method}"},
    }


# ---------------------------------------------------------------------------
# stdio transport: newline-delimited JSON (MCP stdio framing per spec)
# ---------------------------------------------------------------------------
def main():
    log(f"start: {len(TOOLS)} tools from {CONTRACT_DIR}, workspace={WORKSPACE}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            resp = handle(req)
        except Exception as e:  # noqa: BLE001
            resp = {"jsonrpc": "2.0", "id": req.get("id"),
                    "error": {"code": -32603, "message": str(e)}}
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
