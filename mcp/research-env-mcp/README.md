# research-env-v1 — stdio MCP server (thin shim)

A dependency-free Python (stdlib-only) MCP server that exposes the 9 `research-env-v1`
tools to an MCP client (Goose 1.38) over **stdio JSON-RPC 2.0**. ~250 LOC, no framework.

## How it loads the contract (CANONICAL source — nothing hardcoded except dispatch)

On startup it reads `manifest.json` from the contract dir and, for each entry, loads the
referenced `tools/<name>.json` schema. The tool **set**, descriptions, and `inputSchema`s
all come from those files; the server hardcodes only the *dispatch map* (name → impl).
Add/rename a tool in the contract → it shows up here on next start, no code change.

- Contract dir: `RESEARCH_ENV_CONTRACT_DIR` (default: the `contract/research-env-v1/` dir at the repo root, resolved relative to this server file)
- Workspace sandbox: `RESEARCH_ENV_WORKSPACE` (default `./workspace`)

## Side-effect policy

| Tool | Behavior |
|---|---|
| `read_file`, `list_files`, `write_file`, `run_command` | **REAL** local FS, sandboxed to the workspace dir (paths that escape are rejected). |
| `submit_job`, `get_job` | **REAL** Rockie backend (device-auth via `rockie_auth`, `$ROCKIELAB_API_URL`). |
| `web_search`, `fetch_url` | **REAL web**, stdlib `urllib` only, **no backend dependency**. Run directly from this server so local ≡ platform. |
| `finish` | Terminal — echoes the result string. |

Result-string format follows the contract README: success = raw text or pretty JSON;
error = `{"error":{"code","message"}}` in a single text block, with `isError: true`.

### `web_search`
- **Keyless default** (works for free/local/BYOK users out of the box): queries
  DuckDuckGo's HTML endpoint and parses title/url/snippet with stdlib only. If
  DDG rate-limits, returns a clean `rate_limited` error (never a crash).
- **Optional BYO key** for higher quality: set `SEARCH_API_KEY` and (optionally)
  `SEARCH_PROVIDER` ∈ {`tavily` (default), `brave`, `serper`} to route through
  that provider instead.

### `fetch_url`
- Plain HTTP(S) GET → readable text (tags stripped via stdlib). Response capped
  at `FETCH_URL_MAX_BYTES` (default 2 MB); the cap is reported when hit.
- **SSRF-guarded** (the same code runs on tenant machines): refuses non-http(s)
  schemes; resolves the host and blocks private / loopback / link-local /
  reserved / cloud-metadata (`169.254.169.254`) ranges; re-checks the guard on
  every redirect hop (bounded at `FETCH_MAX_REDIRECTS`).

## Wire protocol

MCP over stdio: newline-delimited JSON-RPC 2.0 (one request/response object per line).
Implements `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`.
Protocol version `2024-11-05`.

## Register in Goose (config.yaml)

Goose reads `~/.config/goose/config.yaml`. The `extensions:` map deserializes into
`ExtensionEntry { enabled: bool, #[flatten] ExtensionConfig }` — **`enabled: true` is
REQUIRED**; omitting it makes the whole entry fail to deserialize and Goose silently
drops it ("Skipping malformed extension config entry"). Working snippet:

```yaml
extensions:
  research-env-v1:
    enabled: true            # REQUIRED — without it Goose silently drops the extension
    type: stdio
    name: research-env-v1
    description: Rockie research action space (research-env-v1) — 9 tools over MCP stdio
    cmd: python3
    args:
      - /path/to/rockie-nugget/mcp/research-env-mcp/server.py
    envs:
      RESEARCH_ENV_CONTRACT_DIR: /path/to/rockie-nugget/contract/research-env-v1
      RESEARCH_ENV_WORKSPACE: /path/to/your/workspace
    timeout: 300
```

## Local smoke test (no Goose)

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_files","arguments":{}}}' \
  | RESEARCH_ENV_WORKSPACE=/tmp/ws python3 server.py
```
