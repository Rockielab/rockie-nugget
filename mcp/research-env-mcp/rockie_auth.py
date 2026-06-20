#!/usr/bin/env python3
"""rockie_auth — stdlib-only device-flow client for the Rockie backend.

Reproduces the EXACT contract the shipped `@rockielab/cli` uses (verified against
/tmp/rockie-cli: src/lib/auth.ts, src/lib/config.ts, src/commands/auth.ts,
src/lib/api-client.ts). The CLI is pinned on users' machines, so nugget must
match — not reinvent — its endpoints and shapes.

Resolution / contract (cited to the CLI):
  - Base URL: $ROCKIELAB_API_URL → else https://api.rockielab.com, trailing slash
    stripped. (config.ts DEFAULT_TENANT + the per-invocation $ROCKIELAB_API_URL
    override the design fixes.)
  - Token order (resolveToken, auth.ts): $ROCKIELAB_TENANT_TOKEN env (always
    wins, headless/platform) → ~/.rockie/auth.json (dir overridable by
    $ROCKIE_HOME). The OS-keychain tier the CLI also supports is intentionally
    skipped here (file + env is enough and dependency-light; the CLI itself falls
    back to the file).
  - auth.json shape: { "<base-url>": {token, expires_at, user_email?} }, dir 0700,
    file 0600. (writeAuthFile, auth.ts.)
  - Device flow: POST {base}/api/auth/device/init (empty body) → {device_code,
    user_code, verification_uri, verification_uri_complete?, interval, expires_in};
    POST {base}/api/auth/device/poll {device_code} → {status:
    "authorization_pending"|"complete", ...}. (auth.ts pollForToken /
    loginDeviceFlow.) Pending/slow_down/expired_token are carried in the backend
    error envelope {detail:{error:{code,message}}} (api-client.ts extractDetail).
  - Auth header: Authorization: Bearer <token>.

stdlib only — urllib/json/os. No pip deps (the MCP server is deliberately
dependency-free).

CLI entrypoint:  python3 -m rockie_auth login   (drives the browser device flow)
Tool entrypoint: get_token()  (the resolution order above; None if unauthenticated)
"""
import json
import os
import stat
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

DEFAULT_BASE = "https://api.rockielab.com"
TOKEN_ENV_VAR = "ROCKIELAB_TENANT_TOKEN"


def base_url() -> str:
    """$ROCKIELAB_API_URL → else the CLI default, trailing slash stripped."""
    return os.environ.get("ROCKIELAB_API_URL", DEFAULT_BASE).rstrip("/")


def _rockie_home() -> Path:
    """~/.rockie, overridable by $ROCKIE_HOME (matches CLI config.ts rockieHome)."""
    home = os.environ.get("ROCKIE_HOME")
    return Path(home) if home else (Path.home() / ".rockie")


def auth_file_path() -> Path:
    return _rockie_home() / "auth.json"


# ───────────────────────────── auth.json store ───────────────────────────────
def _read_auth_file() -> dict:
    """Read auth.json, returning {} when absent. Malformed JSON → {} (be lenient
    on read; the CLI throws, but a tool refusing to authenticate over a stray
    byte is worse than re-running login)."""
    path = auth_file_path()
    try:
        raw = path.read_text()
    except FileNotFoundError:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _write_auth_file(data: dict) -> None:
    """Persist auth.json: dir 0700, file 0600, temp+rename (matches CLI)."""
    path = auth_file_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, stat.S_IRWXU)  # 0700
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)  # 0600
    os.replace(tmp, path)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)  # 0600


# ─────────────────────────────── resolution ──────────────────────────────────
def get_token() -> str | None:
    """Resolve the bearer: $ROCKIELAB_TENANT_TOKEN env → auth.json[<base>].token.
    Matches the CLI's frozen env→file order (auth.ts resolveToken)."""
    env = os.environ.get(TOKEN_ENV_VAR)
    if env and env.strip():
        return env.strip()
    cred = _read_auth_file().get(base_url())
    if isinstance(cred, dict):
        tok = cred.get("token")
        if isinstance(tok, str) and tok:
            return tok
    return None


# ───────────────────────────── HTTP (stdlib) ─────────────────────────────────
class AuthHttpError(Exception):
    """A backend error carrying the {detail:{error:{code,message}}} envelope's
    machine `code` (api-client.ts extractDetail), so the poll loop can branch on
    authorization_pending / slow_down / expired_token."""

    def __init__(self, status: int, code: str | None, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def _extract_detail(body: str) -> tuple[str | None, str | None]:
    """Best-effort (message, code) from the Rockie error body — mirrors the CLI's
    extractDetail across the three shapes it handles."""
    try:
        parsed = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        trimmed = (body or "").strip()
        return (trimmed[:200] or None, None)
    detail = parsed.get("detail") if isinstance(parsed, dict) else None
    if isinstance(detail, str):
        return (detail, None)
    if isinstance(detail, dict):
        inner = detail.get("error")
        if isinstance(inner, dict):
            msg = inner.get("message")
            code = inner.get("code")
            return (msg if isinstance(msg, str) else None,
                    code if isinstance(code, str) else None)
        if isinstance(detail.get("code"), str):
            return (None, detail["code"])
    flat = parsed.get("error") or parsed.get("message") if isinstance(parsed, dict) else None
    return (flat if isinstance(flat, str) else None, None)


def request_json(method: str, path: str, body: dict | None = None,
                 token: str | None = None, timeout: float = 30.0) -> dict:
    """Issue an authenticated JSON request and parse the JSON response. Raises
    AuthHttpError (with the envelope `code`) on >=400. urllib only."""
    url = base_url() + path
    data = json.dumps(body).encode() if body is not None else (b"{}" if method == "POST" else None)
    headers = {"Accept": "application/json", "User-Agent": "rockie-nugget"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        msg, code = _extract_detail(raw)
        raise AuthHttpError(e.code, code, msg or f"HTTP {e.code}") from None
    except urllib.error.URLError as e:
        raise AuthHttpError(0, None, f"could not reach {url}: {e.reason}") from None
    return json.loads(raw) if raw.strip() else {}


# ─────────────────────────────── device flow ─────────────────────────────────
def login(timeout_override: float | None = None) -> dict:
    """Drive the browser device flow (auth.ts loginDeviceFlow + pollForToken):
    init → print user_code + verification URL → poll until complete → persist.
    Returns the stored credential. Raises AuthHttpError on expiry/failure."""
    init = request_json("POST", "/api/auth/device/init")
    user_code = init["user_code"]
    verify = init.get("verification_uri_complete") or init["verification_uri"]
    interval = max(1, int(init.get("interval", 5)))
    expires_in = int(init.get("expires_in", 600))

    print(
        f"\nTo finish signing in, open:\n    {init['verification_uri']}\n"
        f"and enter code:\n\n    {user_code}\n",
        file=sys.stderr,
    )
    try:
        webbrowser.open(verify)
    except Exception:  # noqa: BLE001 — headless: the user reads the printed URL
        pass

    deadline = time.time() + (timeout_override if timeout_override is not None else expires_in)
    while True:
        if time.time() >= deadline:
            raise AuthHttpError(0, "expired_token", "Login timed out before approval.")
        time.sleep(interval)
        try:
            res = request_json("POST", "/api/auth/device/poll",
                               body={"device_code": init["device_code"]})
        except AuthHttpError as e:
            if e.code == "authorization_pending":
                continue
            if e.code == "slow_down":
                interval += 5  # RFC 8628 §3.5
                continue
            if e.code == "expired_token":
                raise AuthHttpError(0, "expired_token",
                                    "Login code expired before approval.") from None
            raise
        status = res.get("status")
        if status == "authorization_pending":
            print("Waiting for approval…", file=sys.stderr)
            continue
        if status == "complete":
            cred = {
                "token": res["token"],
                "expires_at": res.get("expires_at"),
            }
            data = _read_auth_file()
            data[base_url()] = cred
            _write_auth_file(data)
            print(f"Signed in to {base_url()}.", file=sys.stderr)
            return cred


def _main(argv: list[str]) -> int:
    if not argv or argv[0] != "login":
        print("usage: python3 -m rockie_auth login", file=sys.stderr)
        return 2
    try:
        login()
        return 0
    except AuthHttpError as e:
        print(f"login failed: {e.message}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nlogin cancelled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
