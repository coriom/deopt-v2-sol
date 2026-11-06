#!/usr/bin/env python3
"""Operator-only Alchemy RPC rotation without secret arguments or output."""

import getpass
import json
import os
from pathlib import Path
import tempfile
import time
from urllib import error, parse, request


ENV_PATH = Path(__file__).resolve().parents[1] / ".env.base-sepolia"
HOST = "base-sepolia.g.alchemy.com"
CHAIN_ID = "0x14a34"  # 84532


def validate_url(value: str) -> None:
    parts = parse.urlsplit(value)
    if (
        parts.scheme != "https"
        or parts.hostname != HOST
        or parts.port is not None
        or parts.username is not None
        or parts.password is not None
        or not parts.path.startswith("/v2/")
        or len(parts.path.split("/", 2)[-1]) < 12
        or parts.query
        or parts.fragment
    ):
        raise ValueError("Expected a Base Sepolia Alchemy HTTPS endpoint")


def rpc_status(url: str) -> str:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}).encode()
    req = request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        with request.urlopen(req, timeout=10) as response:
            payload = json.load(response)
    except error.HTTPError as exc:
        return "DENIED" if exc.code in (401, 403) else "INCONCLUSIVE"
    except Exception:
        return "INCONCLUSIVE"
    if payload.get("result") == CHAIN_ID:
        return "PASS"
    message = str(payload.get("error", {}).get("message", "")).lower()
    if any(fragment in message for fragment in ("invalid api key", "invalid key", "key not found", "unauthorized")):
        return "DENIED"
    return "INCONCLUSIVE"


def replace_rpc_line(text: str, new_url: str) -> str:
    lines = text.splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines) if line.startswith("RPC_URL=")]
    if len(matches) != 1:
        raise ValueError("Expected exactly one RPC_URL line")
    newline = "\n" if lines[matches[0]].endswith("\n") else ""
    lines[matches[0]] = "RPC_URL=" + new_url + newline
    return "".join(lines)


def write_private(path: Path, content: str) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".rpc-rotation-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    if ENV_PATH.stat().st_mode & 0o077:
        print("RPC_CONFIG_PERMISSIONS=FAIL")
        return 1
    current = ENV_PATH.read_text()
    old = next((line.split("=", 1)[1].strip().strip("\"'") for line in current.splitlines()
                if line.startswith("RPC_URL=")), None)
    if old is None:
        print("RPC_CONFIG=FAIL")
        return 1
    validate_url(old)
    print("RPC_PROVIDER=ALCHEMY_BASE_SEPOLIA")
    print("Rotate the matching app key in Alchemy Dashboard > App Settings first.")
    if input("Type ROTATED after the dashboard confirms rotation: ").strip() != "ROTATED":
        print("RPC_ROTATION=NOT_CONFIRMED")
        return 1
    new = getpass.getpass("New full HTTPS endpoint (hidden): ").strip()
    try:
        validate_url(new)
    except ValueError:
        print("NEW_RPC_FORMAT=FAIL")
        return 1
    if new == old or parse.urlsplit(new).path == parse.urlsplit(old).path:
        print("NEW_RPC_DISTINCT=FAIL")
        return 1
    if rpc_status(new) != "PASS":
        print("NEW_RPC_CHAIN_ID=FAIL_OR_INCONCLUSIVE")
        return 1
    write_private(ENV_PATH, replace_rpc_line(current, new))
    print("NEW_RPC_CHAIN_ID=PASS")
    print("LOCAL_RPC_REFERENCE=UPDATED_MODE_0600")
    for attempt in range(10):
        status = rpc_status(old)
        if status == "DENIED":
            print("OLD_RPC_INVALIDATION=PASS")
            return 0
        if status == "INCONCLUSIVE":
            print("OLD_RPC_INVALIDATION=INCONCLUSIVE")
            return 2
        if attempt < 9:
            time.sleep(15)
    print("OLD_RPC_INVALIDATION=NOT_VERIFIED")
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError):
        print("RPC_ROTATION=BLOCKED")
        raise SystemExit(1)
