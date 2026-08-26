#!/usr/bin/env python3
"""Fail when tier-scoped code names a BARE igniteiq.com hostname.

`api` / `data` / `mcp` / `studio`.igniteiq.com are tier-scoped. They resolved to dev until
2026-08-25 and to prod after (studio stayed on dev). Nothing in the code changed; the
meaning of the string did. Four live defects came from that in a single day:

  linq-bridge/index.ts       MCP_URL ?? "https://mcp.igniteiq.com/mcp"   -> prod's MCP
  mcp-server/index.ts        PLATFORM_API_URL ?? "https://api…"          -> prod's API
  vault.js (igniteiq-vault)  PLATFORM_API_URL || 'https://api…'          -> prod's API
  server.ts                  VAULT_URL ? … : "https://data…"             -> prod's Vault

plus promote.yml smoke-testing prod during a DEV promote, and the frontend's
VITE_VAULT_URL default. Every one returned 200 and looked healthy.

WHAT THIS FLAGS — the shape that fails silently, not every mention:

  A. a fallback/default:   ?? "https://api.igniteiq.com"   || '…'   env(...) or default=
  B. an assignment to a host/url/endpoint/base key
  C. anything at all inside a tier-scoped directory (envs/dev, envs/qa)

A bare hostname inside a doc string, a customer-facing curl sample, an OAuth issuer
identifier or a CORS allowlist is NOT flagged — those are correct, and flagging them
would make the rule noise that gets disabled.

Deliberate exceptions live in ALLOW with a reason. Adding one should feel like a decision.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# The BARE host only. `${slug}.studio.igniteiq.com` and `admin.studio.igniteiq.com` are
# different hosts entirely and are correct — the lookbehind stops `}` and `.` counting as
# a word boundary, which made the first version flag every per-tenant invitation URL.
HOST = re.compile(r"(?<![\w.\-}])(?:api|data|mcp|studio)\.igniteiq\.com\b")

# A. the value is a fallback for a missing configuration value
FALLBACK = re.compile(
    r"(\?\?|\|\||process\.env|import\.meta\.env|os\.environ|getenv|:-|"
    r"^\s*default\s*=|\bdefault:|\?\s*[^:]+:)",
    re.IGNORECASE,
)
# B. the value is being assigned to something that names an endpoint
ASSIGN = re.compile(r"\b\w*(host|url|endpoint|base|origin)\w*\s*[:=]", re.IGNORECASE)
# C. tier-scoped directories: a bare hostname here is wrong by construction
TIER_DIRS = ("envs/dev/", "envs/qa/", "envs/prod/")

CODE_EXT = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".yml", ".yaml",
            ".tf", ".tfvars", ".json", ".sh", ".sql", ".toml", ".ini", ".conf"}

SKIP = ("archive/", "node_modules/", "dist/", "prisma/migrations/", "__tests__/",
        # This file. A linter's fixtures must contain the patterns it detects, so it
        # flags its own docstring and self-test — 13 violations, all of them examples.
        # Caught only in CI: `git ls-files` skips untracked files, so a local run before
        # `git add` scanned everything EXCEPT the new checker. Run it against a committed
        # tree before believing a clean result.
        "scripts/check_bare_hostnames.py")

# ── per-repo configuration ───────────────────────────────────────────────────────
# This FILE is byte-identical in every repo that carries it; everything repo-specific
# lives in the sidecar JSON beside it. Five hand-maintained copies of a rule is how a
# rule stops being the same rule — the fleet guard can assert the .py matches, and it
# can only do that if there is nothing local in it.
#
#   allow : path -> why a bare hostname there is correct (never covers a fallback)
#   known : "path:line" -> a REAL violation, tracked not excused, printed every run
CONFIG_NAME = "bare_hostnames.config.json"


def load_config(script_dir):
    path = os.path.join(script_dir, CONFIG_NAME)
    if not os.path.exists(path):
        raise SystemExit(
            f"missing {path}\n"
            "  This script is repo-agnostic; the allow/known lists live beside it.\n"
            "  Refusing to run with an empty config — that would silently pass a repo\n"
            "  whose exceptions were never reviewed."
        )
    with open(path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    return cfg.get("allow", {}), cfg.get("known", {})


def tracked(root):
    out = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True)
    return [f for f in out.stdout.splitlines() if f]


INLINE_OK = re.compile(r"bare-host-ok:")


def classify(rel, line):
    """Return (reason, file_allowlistable) if this line is a violation, else None.

    A FALLBACK is never file-allowlistable. That distinction is the whole point: the
    first version of this script allowlisted services/mcp-server/index.ts and
    services/api/src/server.ts wholesale for their OAuth identifiers and CORS entries,
    and thereby suppressed the PLATFORM_API_URL and VAULT_URL fallbacks on those same
    files - two of the four defects it was written to catch. A file-level exemption
    granted for one good reason must not silently cover a different, bad line.

    Genuine fallback exceptions carry an inline `bare-host-ok: <reason>` marker, so the
    exemption sits on the line it excuses and cannot drift onto a new one.
    """
    if INLINE_OK.search(line):
        return None
    if FALLBACK.search(line):
        return ("bare hostname used as a fallback/default for a config value", False)
    if any(rel.startswith(d) for d in TIER_DIRS):
        return ("bare hostname inside a tier-scoped directory", True)
    if ASSIGN.search(line):
        return ("bare hostname assigned to a host/url/endpoint key", True)
    return None


def scan(root, allow=None, known_cfg=None):
    """known_cfg is the CONFIG dict; `known` below is the list of hits found.

    These were briefly both called `known`, so `f"{rel}:{n}" in known` tested membership
    in the growing list of hit tuples and was always False — every tracked violation
    silently became a new one. Keep the names distinct.
    """
    allow = {} if allow is None else allow
    known_cfg = {} if known_cfg is None else known_cfg
    violations, allowed, known = [], [], []
    for rel in tracked(root):
        if any(s in rel for s in SKIP):
            continue
        if os.path.splitext(rel)[1].lower() not in CODE_EXT:
            continue
        path = os.path.join(root, rel)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            if not HOST.search(line):
                continue
            hit = classify(rel, line)
            if not hit:
                continue
            reason, exemptible = hit
            if f"{rel}:{n}" in known_cfg:
                known.append((rel, n, reason, line.strip()[:120]))
            elif exemptible and rel in allow:
                allowed.append((rel, n, reason, line.strip()[:120]))
            else:
                violations.append((rel, n, reason, line.strip()[:120]))
    return violations, allowed, known


def self_test():
    import tempfile

    # Every one of these is a real line that shipped a defect.
    must_flag = [
        ("services/x.ts", 'const MCP_URL = process.env.MCP_URL ?? "https://mcp.igniteiq.com/mcp";'),
        ("services/y.ts", "const P = process.env.PLATFORM_API_URL || 'https://api.igniteiq.com';"),
        ("vault.js", 'const U = process.env.VAULT_URL ? process.env.VAULT_URL : "https://data.igniteiq.com";'),
        ("a/b.tf", '  default     = "https://api.igniteiq.com"'),
        ("envs/dev/main.tf", '  platform_api_url = "https://api.igniteiq.com"'),
        ("w.yml", '              echo "api_host=api.igniteiq.com" >> "$GITHUB_OUTPUT"'),
        ("s.tsx", 'import.meta.env.VITE_VAULT_URL || "https://data.igniteiq.com/cubejs-api/v1";'),
        ("f.sh", 'BASE="${IGNITEIQ_API:-https://api.igniteiq.com}"'),
        ("g.py", 'VAULT = os.environ.get("VAULT_URL", "https://data.igniteiq.com")'),
    ]
    # These are correct and must stay quiet, or the rule becomes noise and gets disabled.
    must_pass = [
        ("d.ts", '  curl -X POST https://api.igniteiq.com/v1/query \\\\'),
        ("d.ts", '    "url": "https://mcp.igniteiq.com/mcp",'),
        ("d.ts", '  // data.igniteiq.com eventually becomes internal-only (ENG-303).'),
        ("d.ts", '  <Link href="https://studio.igniteiq.com" style={footerLink}>'),
        ("d.ts", "  expect(p.type).toBe('https://api.igniteiq.com/errors/forbidden');"),
        ("d.ts", '  return `https://${slug}.studio.igniteiq.com`;'),
    ]

    fails = []
    for rel, line in must_flag:
        if not classify(rel, line):
            fails.append(f"MISSED: {rel}  {line.strip()[:80]}")
    for rel, line in must_pass:
        r = classify(rel, line)
        if r:
            fails.append(f"FALSE POSITIVE ({r[0]}): {line.strip()[:80]}")

    # A file-level exemption must NOT cover a fallback on that same file. This is the
    # bug the first version of this script shipped with.
    fb = classify("services/mcp-server/index.ts",
                  'const P = process.env.PLATFORM_API_URL ?? "https://api.igniteiq.com";')
    if fb is None or fb[1] is not False:
        fails.append("a fallback was marked file-allowlistable — it must never be")
    # and an inline marker must excuse exactly its own line
    if classify("x.ts", 'const P = process.env.X ?? "https://api.igniteiq.com";  // bare-host-ok: operator tool') is not None:
        fails.append("inline bare-host-ok marker did not suppress its line")

    # allowlisting must suppress an EXEMPTIBLE violation, and only for the named file.
    # An assignment is exemptible; a fallback is not, which the fb check above pins.
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "svc"), exist_ok=True)
        bad = 'const base_url = "https://api.igniteiq.com";\n'
        open(os.path.join(tmp, "svc", "a.ts"), "w").write(bad)
        open(os.path.join(tmp, "svc", "b.ts"), "w").write(bad)
        subprocess.run(["git", "-C", tmp, "init", "-q"], check=True)
        subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
        v, a, _k = scan(tmp, allow={})
        if len(v) != 2:
            fails.append(f"expected 2 violations in fixture, got {len(v)}")
        v, a, _k = scan(tmp, allow={"svc/a.ts": "test"})
        if len(v) != 1 or len(a) != 1:
            fails.append(f"allowlist wrong: {len(v)} violations / {len(a)} allowed")
        if v and v[0][0] != "svc/b.ts":
            fails.append("allowlist suppressed the wrong file")

        # The KNOWN path, end to end. Both refactor bugs — a config dict shadowed by the
        # local hit list, and a print that dereferenced the list as a dict — passed the
        # self-test, because nothing here had ever exercised tracking. A self-test that
        # never runs a branch cannot defend it.
        open(os.path.join(tmp, "svc", "k.ts"), "w").write(
            'const U = process.env.X ?? "https://api.igniteiq.com";\n')
        subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
        vk, ak, kk = scan(tmp, allow={}, known_cfg={"svc/k.ts:1": "tracked in the fixture"})
        if not any(r == "svc/k.ts" for r, *_ in kk):
            fails.append("a known-listed line was not routed to the tracked bucket")
        if any(r == "svc/k.ts" for r, *_ in vk):
            fails.append("a known-listed line ALSO counted as a new violation")
        # and the wrong line number must NOT be excused
        _v2, _a2, k2 = scan(tmp, allow={}, known_cfg={"svc/k.ts:99": "wrong line"})
        if any(r == "svc/k.ts" for r, *_ in k2):
            fails.append("known matched on the wrong line number — path:line must be exact")

        # end-to-end: a FALLBACK inside an allowlisted file must still be reported
        open(os.path.join(tmp, "svc", "c.ts"), "w").write(
            'const U = process.env.X ?? "https://api.igniteiq.com";\n')
        subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
        v2, a2, _k2 = scan(tmp, allow={"svc/c.ts": "allowlisted for some other reason"})
        if not any(r == "svc/c.ts" for r, *_ in v2):
            fails.append("a fallback in an allowlisted file was suppressed end-to-end")

    if fails:
        print("self-test FAIL:", file=sys.stderr)
        for f in fails:
            print(f"  {f}", file=sys.stderr)
        return 1
    print(f"self-test OK — flags all {len(must_flag)} real defect shapes, "
          f"stays quiet on {len(must_pass)} legitimate uses, allowlist scopes to one file")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    allow, known_cfg = load_config(os.path.dirname(os.path.abspath(__file__)))
    violations, allowed, known = scan(args.root, allow, known_cfg)

    if allowed:
        print(f"{len(allowed)} bare-hostname line(s) in allowlisted files (deliberate):")
        for rel in sorted({r for r, *_ in allowed}):
            print(f"  {rel}  — {allow[rel]}")
        print()

    if known:
        print(f"{len(known)} TRACKED violation(s) — real, not excused, not yet fixable in code:")
        for rel, n, _r, line in known:
            print(f"  {rel}:{n}")
            print(f"      {line}")
            print(f"      {known_cfg[f'{rel}:{n}']}")
        print()

    if not violations:
        print("OK — no NEW bare igniteiq.com hostname in a fallback, assignment or tier-scoped file.")
        return 0

    print(f"::error::{len(violations)} bare-hostname violation(s)")
    for rel, n, reason, line in violations:
        print(f"  {rel}:{n}")
        print(f"      {reason}")
        print(f"      {line}")
    print("""
api/data/mcp/studio.igniteiq.com are TIER-SCOPED. They meant dev before 2026-08-25 and
prod after; code referencing them changed meaning without changing.

Use the tier's own hostname (api-qa / api-prod) or resolve the service URL at runtime.
If the bare name is genuinely correct — a customer-facing sample, an OAuth identifier, a
CORS entry — add the file to ALLOW in this script with the reason.""")
    return 1


if __name__ == "__main__":
    sys.exit(main())
