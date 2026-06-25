#!/usr/bin/env python3
"""Fail2Ban → Cloudflare IP List ban / unban helper.

Invoked by docker/azure/status/fail2ban/action.d/cloudflare-api.conf with:

    cloudflare-ban-helper.py add    <ip> "<comment>"
    cloudflare-ban-helper.py remove <ip>

Reads credentials and CF resource IDs from docker-secret files mounted at
/run/secrets/ (backed by /opt/minecraft/secrets/* on the host, written by
docker/azure/refresh-env.sh from Azure Key Vault):

    /run/secrets/cloudflare_api_token     — Bearer token (scoped to one zone +
                                            "Account: Filter Lists: Edit")
    /run/secrets/cloudflare_account_id    — CF account ID (32-char hex)
    /run/secrets/cloudflare_list_id       — IP list ID (32-char hex)

CF API reference:
  https://developers.cloudflare.com/api/operations/lists-create-list-items
  https://developers.cloudflare.com/api/operations/lists-delete-list-items

Why a Python helper and not a curl one-liner in action.d/cloudflare-api.conf:

  1. crazymax/fail2ban does NOT ship `jq`. Parsing the list-search response
     to find the item ID for unban needs a JSON parser; Python stdlib gives
     us that for free.
  2. fail2ban's actionban / actionunban directives don't compose well with
     multi-line shell pipelines (they're single-command). A helper script
     keeps the action.d/ file readable and the multi-step CF flow
     (find item-id → delete) atomic.
  3. urllib + json are stdlib — no extra packages in the image.

Exit codes:
  0  on success (including "IP not in list, nothing to unban" — idempotent).
  1  on usage error.
  2  on CF API failure (HTTP non-2xx, or success=false body). fail2ban will
     log the failure and the ban stays effective at the jail level (local DB)
     even if the CF blocklist update was rejected.
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

SECRETS_DIR = Path("/run/secrets")
CF_API_BASE = "https://api.cloudflare.com/client/v4"


def read_secret(name: str) -> str:
    """Read a docker-secret file, stripping trailing whitespace."""
    path = SECRETS_DIR / name
    try:
        return path.read_text().strip()
    except FileNotFoundError:
        # Resolve the original KV secret name for the operator (e.g.
        # cloudflare_api_token → cloudflare-api-token).
        kv_name = name.replace("_", "-")
        sys.stderr.write(
            f"ERROR: secret file {path} missing — refresh-env.sh on the host "
            f"may not have populated /opt/minecraft/secrets/ yet, or the KV "
            f"secret {kv_name} is empty.\n"
        )
        sys.exit(2)


def cf_request(
    method: str,
    url: str,
    token: str,
    body: dict | list | None = None,
) -> dict:
    """Call the CF API and return parsed JSON. Exits 2 on failure."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            err_body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            err_body = "<unreadable>"
        sys.stderr.write(
            f"ERROR: Cloudflare API {method} {url} failed: "
            f"HTTP {exc.code} {exc.reason}\n{err_body}\n"
        )
        sys.exit(2)
    except urllib.error.URLError as exc:
        sys.stderr.write(
            f"ERROR: Cloudflare API {method} {url} unreachable: {exc.reason}\n"
        )
        sys.exit(2)


def ban(ip: str, comment: str, token: str, account_id: str, list_id: str) -> None:
    """Append <ip> to the CF IP list with a fail2ban-traceable comment."""
    url = f"{CF_API_BASE}/accounts/{account_id}/rules/lists/{list_id}/items"
    body = [{"ip": ip, "comment": comment}]
    resp = cf_request("POST", url, token, body)
    if not resp.get("success", False):
        sys.stderr.write(
            f"ERROR: CF API returned success=false on ban: {json.dumps(resp)}\n"
        )
        sys.exit(2)
    # CF returns an operation_id for the async list update — log it for
    # traceability against the CF audit log.
    op_id = (resp.get("result") or {}).get("operation_id", "<none>")
    print(f"banned {ip} → CF list (op {op_id}, comment: {comment})")


def unban(ip: str, token: str, account_id: str, list_id: str) -> None:
    """Find the list-item-id matching <ip> and DELETE it. Idempotent."""
    # CF's per-list items endpoint takes ?search=<substring> and returns
    # up to ?per_page=N items. For IPs this is effectively exact-match,
    # but we still iterate the result set defensively in case the same IP
    # was banned twice with different comments (which CF stores as two
    # list items — both need deleting).
    search_url = (
        f"{CF_API_BASE}/accounts/{account_id}/rules/lists/{list_id}/items"
        f"?search={ip}&per_page=25"
    )
    resp = cf_request("GET", search_url, token)
    if not resp.get("success", False):
        sys.stderr.write(
            f"ERROR: CF API list search returned success=false: {json.dumps(resp)}\n"
        )
        sys.exit(2)

    matching_ids = [
        item["id"]
        for item in resp.get("result", [])
        if item.get("ip") == ip
    ]
    if not matching_ids:
        # Idempotent: an IP that isn't in the list is already "unbanned".
        # Could happen if the IP was manually removed via the CF dashboard
        # before fail2ban's bantime expired and triggered this.
        print(f"unban {ip}: not in CF list, nothing to do")
        return

    del_url = f"{CF_API_BASE}/accounts/{account_id}/rules/lists/{list_id}/items"
    body = {"items": [{"id": item_id} for item_id in matching_ids]}
    resp = cf_request("DELETE", del_url, token, body)
    if not resp.get("success", False):
        sys.stderr.write(
            f"ERROR: CF API delete returned success=false: {json.dumps(resp)}\n"
        )
        sys.exit(2)
    op_id = (resp.get("result") or {}).get("operation_id", "<none>")
    print(
        f"unbanned {ip} → CF list "
        f"(op {op_id}, removed {len(matching_ids)} item(s))"
    )


def main(argv: list[str]) -> None:
    if len(argv) < 3:
        sys.stderr.write(
            "Usage: cloudflare-ban-helper.py add    <ip> \"<comment>\"\n"
            "       cloudflare-ban-helper.py remove <ip>\n"
        )
        sys.exit(1)

    action, ip = argv[1], argv[2]
    token = read_secret("cloudflare_api_token")
    account_id = read_secret("cloudflare_account_id")
    list_id = read_secret("cloudflare_list_id")

    if action == "add":
        comment = argv[3] if len(argv) > 3 else "fail2ban"
        ban(ip, comment, token, account_id, list_id)
    elif action == "remove":
        unban(ip, token, account_id, list_id)
    else:
        sys.stderr.write(f"Unknown action: {action!r}\n")
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv)
