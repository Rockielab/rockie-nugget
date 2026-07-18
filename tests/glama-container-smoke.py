#!/usr/bin/env python3
"""Exercise the research-env-v1 MCP handshake over a command's stdio."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


REQUESTS = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "write_file",
            "arguments": {"path": "glama-proof.txt", "content": "writable\n"},
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {"name": "list_files", "arguments": {}},
    },
]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(f"usage: {sys.argv[0]} COMMAND [ARG ...]")

    repo_root = Path(__file__).resolve().parents[1]
    env = os.environ.copy()
    env.setdefault(
        "RESEARCH_ENV_CONTRACT_DIR",
        str(repo_root / "contract" / "research-env-v1"),
    )

    with tempfile.TemporaryDirectory() as workspace:
        env["RESEARCH_ENV_WORKSPACE"] = workspace
        payload = "\n".join(json.dumps(request) for request in REQUESTS) + "\n"
        result = subprocess.run(
            sys.argv[1:],
            input=payload,
            text=True,
            capture_output=True,
            env=env,
            timeout=30,
            check=False,
        )

    require(
        result.returncode == 0,
        f"server exited {result.returncode}; stderr:\n{result.stderr}",
    )
    responses = [json.loads(line) for line in result.stdout.splitlines() if line]
    require(len(responses) == 4, f"expected 4 responses, got: {result.stdout!r}")
    by_id = {response.get("id"): response for response in responses}

    initialize = by_id[1]["result"]
    require(initialize["protocolVersion"] == "2024-11-05", initialize)
    require(initialize["serverInfo"]["name"] == "research-env-v1", initialize)

    tools = by_id[2]["result"]["tools"]
    tool_names = {tool["name"] for tool in tools}
    require(len(tools) == 9, f"expected 9 research-env-v1 tools, got {tool_names}")
    require("list_files" in tool_names, f"list_files missing from {tool_names}")

    write_file = by_id[3]["result"]
    require(write_file["isError"] is False, write_file)
    require(
        write_file["content"]
        == [{"type": "text", "text": "wrote glama-proof.txt (9 bytes)"}],
        write_file,
    )

    list_files = by_id[4]["result"]
    require(list_files["isError"] is False, list_files)
    require(
        list_files["content"]
        == [{"type": "text", "text": "glama-proof.txt"}],
        list_files,
    )
    print(
        "Glama container stdio proof passed: initialize, tools/list, "
        "write_file, list_files"
    )


if __name__ == "__main__":
    main()
