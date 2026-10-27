#!/usr/bin/env python3
"""Does this customer project actually look like a provisioned project?

    scripts/check_provision_parity.py --project eco-igniteiq-data --slug eco
    scripts/check_provision_parity.py --self-test

ENG-433. Eco Home Services was deployed white-glove on 2026-08-04 and FIVE separate
provisioning steps were missed, every one of which this terraform declares correctly:

    1. depot-sa's ST-secret secretAccessor grants          (secrets.tf st_depot_reader)
    2. the four <slug>-servicetitan-* secret shells        (secrets.tf st)
    3. platform SA secretmanager.secretVersionAdder        (iam.tf platform_secret_version_adder)
    4. platform SA bigquery jobUser/dataViewer/metadataViewer (iam.tf platform_bq_*)
    5. forge SA project-level bigquery.dataEditor          (iam.tf forge_data_editor)

Gap 4 was customer-visible: Studio's Raw Tables page rendered
"BigQuery jobs.query -> 403: User does not have bigquery.jobs.create permission".
iam.tf's own comment predicts that failure verbatim. So it had been found and solved once,
on the self-serve path, and the hand-run white-glove path never learned it.

WHY THIS COMPARES AGAINST TERRAFORM, NOT AGAINST ANOTHER TENANT.

Diffing a new project against a known-good tenant is what found gaps 3 and 4, and it is a
good instinct — but it inherits that tenant's mistakes. Proof from the same day: vault-sa was
granted PROJECT-level bigquery.dataViewer on Eco because Reynolds has it, while this module
grants it DATASET-scoped on `ontology` only. Both tenants are wider than the specification, so
no tenant-to-tenant diff could ever have shown it. The terraform is the specification; a
reference tenant is only a copy of one.

AND WHY IT PARSES THE .tf FILES RATHER THAN LISTING WHAT TO CHECK.

A hand-written list of expected grants would share the blind spot of the thing it checks — add
a resource to iam.tf and the list silently stops covering it. That is
[[a_guard_with_a_hand_list_guards_nothing]], and it is the specific reason a subset IAM diff
(three ingestion SAs) declared parity on Eco while gap 4 survived to 403 a customer. So the
expectations are DERIVED: add a google_project_iam_member to iam.tf and this check covers it
on the next run, with no edit here.

Read-only. Makes no changes and needs only viewer-level access on the target project.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


# ── terraform parsing: derive the expectation from the declaration ──────────────────

def _hcl_bodies(src: str, kind: str) -> list[tuple[str, str]]:
    """Yield (resource_name, body) for each `resource "<kind>" "<name>" { ... }`.

    Brace-counted rather than regex-matched to the closing brace, because bodies contain
    nested blocks (`replication { auto {} }`) that a lazy regex would cut short.
    """
    out: list[tuple[str, str]] = []
    for m in re.finditer(rf'resource\s+"{re.escape(kind)}"\s+"([^"]+)"\s*\{{', src):
        i = m.end()
        depth = 1
        while i < len(src) and depth:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
            i += 1
        out.append((m.group(1), src[m.end() : i - 1]))
    return out


def _attr(body: str, name: str) -> str | None:
    m = re.search(rf'^\s*{re.escape(name)}\s*=\s*(.+?)\s*$', body, re.M)
    return m.group(1).strip() if m else None


# The Depot v2 resources ride in the same files, gated on depot_v2_enabled: a
# `count = local.v2` or a `for_each` that branches on `var.depot_v2_enabled` (ENG-1021). With
# the flag off, Terraform creates none of them, so the spec must derive none of them — else
# every tenant reads as missing a set of grants and secrets it was never meant to have.
# It reads variable DEFAULTS, not a tenant's tfvars; --enable turns a bool flag on for a tenant
# that set it. Off is the only state modelled for v2: a for_each'd v2 secret now resolves its
# own key set, but `count = local.v2_only` is not evaluated, so --enable depot_v2_enabled would
# still mis-derive the relay grants until that is taught too.
_V2_GATES = ("local.v2", "var.depot_v2_enabled")


def _v2_gated(body: str) -> bool:
    gate = f"{_attr(body, 'count') or ''} {_attr(body, 'for_each') or ''}"
    return any(g in gate for g in _V2_GATES)


def _var_defaults(src: str) -> dict[str, str]:
    """variable "x" { ... default = "y" } -> {x: y}. Only string defaults matter here."""
    out: dict[str, str] = {}
    for name, body in _hcl_bodies(src.replace('resource "', 'resource "x" "').replace("variable ", 'resource "variable" '), "variable"):
        pass  # unreachable; kept simple below
    for m in re.finditer(r'variable\s+"([^"]+)"\s*\{', src):
        i, depth = m.end(), 1
        while i < len(src) and depth:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
            i += 1
        body = src[m.end() : i - 1]
        d = _attr(body, "default")
        if d and d.startswith('"'):
            out[m.group(1)] = d.strip('"')
    return out


def _var_list_defaults(src: str) -> dict[str, list[str]]:
    """variable "x" { type = set(string) ... default = ["a", "b"] } -> {x: ["a", "b"]}.

    Separate from _var_defaults, which reads only string defaults. A for_each'd resource
    resolves to N members rather than one, and a string-only reader returns NONE of them —
    so the derived spec would quietly shrink instead of failing. That is the exact shape of
    [[a_guard_with_a_hand_list_guards_nothing]], so _expand raises rather than returning [].
    """
    out: dict[str, list[str]] = {}
    for m in re.finditer(r'variable\s+"([^"]+)"\s*\{', src):
        i, depth = m.end(), 1
        while i < len(src) and depth:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
            i += 1
        body = src[m.end() : i - 1]
        d = re.search(r'default\s*=\s*\[(.*?)\]', body, re.S)
        if d:
            out[m.group(1)] = re.findall(r'"([^"]+)"', d.group(1))
    return out


def _bool_var_defaults(src: str) -> dict[str, bool]:
    """Every `variable "x" { type = bool ... default = true|false }` -> {x: bool}."""
    out: dict[str, bool] = {}
    for m in re.finditer(r'variable\s+"([^"]+)"\s*\{', src):
        i, depth = m.end(), 1
        while i < len(src) and depth:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
            i += 1
        body = src[m.end() : i - 1]
        if (_attr(body, "type") or "") == "bool":
            out[m.group(1)] = (_attr(body, "default") or "false") == "true"
    return out


def _list_local(src: str, name: str) -> list[str]:
    m = re.search(rf'(?<![\w.]){re.escape(name)}\s*=\s*\[(.*?)\]', src, re.S)
    if not m:
        return []
    return re.findall(r'"([^"]+)"', m.group(1))


class Spec:
    """The declared shape of a provisioned project, read out of the .tf files."""

    def __init__(self, project: str, slug: str, root: Path = REPO, enable: tuple[str, ...] = ()) -> None:
        iam = (root / "iam.tf").read_text()
        secrets = (root / "secrets.tf").read_text()
        variables = (root / "variables.tf").read_text()
        locals_ = (root / "locals.tf").read_text()

        self.project, self.slug = project, slug
        self.locals_src = locals_
        # Variable DEFAULTS, then the bool flags a tenant's tfvars turn on (--enable).
        self.flags = _bool_var_defaults(variables)
        for name in enable:
            if name not in self.flags:
                raise RuntimeError(f"--enable {name}: no bool variable of that name in variables.tf")
            self.flags[name] = True
        self.v2_enabled = self.flags.get("depot_v2_enabled", False)
        self.vars = _var_defaults(variables)
        self.var_lists = _var_list_defaults(variables)
        self.sa_emails = {
            n: f"{_attr(b, 'account_id').strip(chr(34))}@{project}.iam.gserviceaccount.com"
            for n, b in _hcl_bodies(iam, "google_service_account")
        }

        self.project_iam: set[tuple[str, str]] = set()
        for _, body in _hcl_bodies(iam, "google_project_iam_member"):
            if self._off(body):
                continue
            role, member = _attr(body, "role"), _attr(body, "member")
            if role and member:
                for one in self._expand(body, member):
                    self.project_iam.add((self._resolve(role), one))

        self.dataset_iam: set[tuple[str, str, str]] = set()
        for _, body in _hcl_bodies(iam, "google_bigquery_dataset_iam_member"):
            if self._off(body):
                continue
            ds, role, member = _attr(body, "dataset_id"), _attr(body, "role"), _attr(body, "member")
            if ds and role and member:
                m = re.search(r'datasets\["([^"]+)"\]', ds)
                name = m.group(1) if m else self._resolve(ds)
                for one in self._expand(body, member):
                    self.dataset_iam.add((name, self._resolve(role), one))

        # Each secret resource resolves its OWN for_each. Expanding every `each.value` with one
        # resource's field list derives wrong ids for every other for_each'd secret, and still
        # passes: the ids it invents are as well-formed as the real ones.
        self.secret_ids: dict[str, dict[str, str]] = {}  # resource name -> {each.key: secret_id}
        for name, body in _hcl_bodies(secrets, "google_secret_manager_secret"):
            if self._off(body):
                self.secret_ids[name] = {}
                continue
            sid = _attr(body, "secret_id")
            if not sid:
                continue
            keys = self._for_each_keys(body)
            if keys is None:
                if "each." in sid:
                    raise RuntimeError(f"google_secret_manager_secret.{name} uses each.* with no for_each")
                self.secret_ids[name] = {"": self._resolve(sid)}
            else:
                self.secret_ids[name] = {
                    k: self._resolve(sid.replace("${each.value}", k).replace("${each.key}", k)) for k in keys
                }
        self.secrets: set[str] = {s for ids in self.secret_ids.values() for s in ids.values()}

        self.secret_iam: set[tuple[str, str, str]] = set()
        for name, body in _hcl_bodies(secrets, "google_secret_manager_secret_iam_member"):
            if self._off(body):
                continue
            role, member = _attr(body, "role"), _attr(body, "member")
            if not (role and member):
                continue
            for t in self._secret_targets(name, body):
                self.secret_iam.add((t, self._resolve(role), self._resolve(member)))

    def _off(self, body: str) -> bool:
        """A Depot v2 resource while depot_v2_enabled is false: not provisioned, so not expected."""
        return _v2_gated(body) and not self.v2_enabled

    # Anything below that it cannot read RAISES. A for_each it guesses at derives a plausible
    # spec, and a plausible wrong spec is the failure this file exists to prevent.

    def _for_each_keys(self, body: str) -> list[str] | None:
        """The keys a resource's for_each yields; None when it has no for_each.

        Understands `<flag> ? <set> : toset([])` and the sets _set_values reads.
        """
        fe = _attr(body, "for_each")
        if not fe:
            return None
        m = re.fullmatch(r"(.+?)\s*\?\s*(.+?)\s*:\s*toset\(\[\]\)", fe)
        if m:
            if not self._truthy(m.group(1)):
                return []
            fe = m.group(2)
        return self._set_values(fe)

    def _truthy(self, cond: str) -> bool:
        cond = cond.strip()
        m = re.fullmatch(r"var\.(\w+)", cond)
        if m and m.group(1) in self.flags:
            return self.flags[m.group(1)]
        # local.x == 1, where locals.tf has `x = var.flag ? 1 : 0`
        m = re.fullmatch(r"local\.(\w+)\s*==\s*1", cond)
        if m:
            d = re.search(rf"(?m)^\s*{re.escape(m.group(1))}\s*=\s*var\.(\w+)\s*\?\s*1\s*:\s*0\s*$", self.locals_src)
            if d and d.group(1) in self.flags:
                return self.flags[d.group(1)]
        raise RuntimeError(f"cannot evaluate for_each condition `{cond}`; teach Spec._truthy about it")

    def _set_values(self, expr: str) -> list[str]:
        expr = expr.strip()
        m = re.fullmatch(r"toset\(local\.(\w+)\)", expr)
        if m:
            vals = _list_local(self.locals_src, m.group(1))
            if vals:
                return vals
        m = re.fullmatch(r"toset\(\[(.*)\]\)", expr)
        if m and m.group(1).strip():
            return re.findall(r'"([^"]+)"', m.group(1))
        m = re.fullmatch(r"var\.(\w+)", expr)
        if m and self.var_lists.get(m.group(1)):
            return self.var_lists[m.group(1)]
        raise RuntimeError(f"cannot resolve for_each `{expr}` to a list of values; teach Spec._set_values about it")

    def _secret_targets(self, name: str, body: str) -> list[str]:
        """The secret ids one google_secret_manager_secret_iam_member resource binds."""
        sid = (_attr(body, "secret_id") or "").strip()
        fe = (_attr(body, "for_each") or "").strip()
        m = re.fullmatch(r"google_secret_manager_secret\.(\w+)", fe)
        if m and sid == "each.value.secret_id":
            return sorted(self._secret_ids_of(m.group(1), name).values())
        m = re.fullmatch(r"google_secret_manager_secret\.(\w+)\[each\.key\]\.secret_id", sid)
        if m:
            ids = self._secret_ids_of(m.group(1), name)
            keys = self._for_each_keys(body)
            if keys is None or any(k not in ids for k in keys):
                raise RuntimeError(f"{name}: keys {keys} are not instances of google_secret_manager_secret.{m.group(1)}")
            return sorted(ids[k] for k in keys)
        m = re.fullmatch(r"google_secret_manager_secret\.(\w+)\.secret_id", sid)
        if m:
            return sorted(self._secret_ids_of(m.group(1), name).values())
        if sid.startswith('"') and "each." not in sid and not fe:
            return [self._resolve(sid)]
        raise RuntimeError(f"cannot resolve the secrets google_secret_manager_secret_iam_member.{name} binds "
                           f"(for_each `{fe}`, secret_id `{sid}`); teach Spec._secret_targets about it")

    def _secret_ids_of(self, secret: str, member: str) -> dict[str, str]:
        if secret not in self.secret_ids:
            raise RuntimeError(f"{member} refers to google_secret_manager_secret.{secret}, which secrets.tf does not declare")
        return self.secret_ids[secret]

    def _expand(self, body: str, raw: str) -> list[str]:
        """One member, or N of them when the resource is for_each'd over a variable set.

        Raises on a for_each whose variable it cannot read. Returning [] would drop every
        grant that resource declares and still print "self-test PASS" — a checker reporting
        parity on expectations it silently failed to derive is worse than no checker.
        """
        fe = _attr(body, "for_each")
        if not (fe and "each.value" in raw):
            return [self._resolve(raw)]
        m = re.search(r"var\.([A-Za-z0-9_]+)", fe)
        vals = self.var_lists.get(m.group(1)) if m else None
        if not vals:
            raise RuntimeError(
                f"for_each over `{fe.strip()}` could not be resolved to a list of values, so "
                f"the grants declared by this resource would be silently omitted from the spec. "
                f"Teach _var_list_defaults about it rather than letting the check under-derive."
            )
        return [self._resolve(raw.replace("${each.value}", v)) for v in vals]

    def _resolve(self, raw: str) -> str:
        v = raw.strip().strip('"')
        v = v.replace("${var.project_id}", self.project).replace("${var.slug}", self.slug)
        for name, val in self.vars.items():
            v = v.replace(f"${{var.{name}}}", val)
        for name, email in self.sa_emails.items():
            v = v.replace(f"${{google_service_account.{name}.email}}", email)
        return v


# ── live state ─────────────────────────────────────────────────────────────────────

def _gcloud(args: list[str], impersonate: str | None) -> str:
    """Run gcloud, never interactively.

    ⚠️ `--quiet` and a closed stdin are load-bearing, not tidiness. On redwood,
    `gcloud secrets list` found Secret Manager disabled and asked
    "Would you like to enable and retry (y/N)?", then waited on stdin forever — the check
    hung instead of reporting. A gate that hangs is worse than one that fails: a red run gets
    read, a hung run gets killed and forgotten. `--quiet` also guarantees it can never
    ENABLE an API or mutate anything while answering a prompt on our behalf.
    """
    cmd = ["gcloud", *args, "--format=json", "--quiet"]
    if impersonate:
        cmd.append(f"--impersonate-service-account={impersonate}")
    r = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {_why_it_failed(r.stderr)}")
    return r.stdout


def _why_it_failed(stderr: str) -> str:
    """The ERROR line, not whatever gcloud printed first.

    ⚠️ Truncating raw stderr puts gcloud's noise ahead of its diagnosis. With
    --impersonate-service-account, gcloud always emits a WARNING about impersonation FIRST,
    so a 300-char slice reported "cannot read <project>'s IAM policy (WARNING: This command
    is using service account impersonation…)" and hid the actual cause — an expired token
    needing reauth — past the cut. The failure was legible only by re-running the command by
    hand, which is exactly the work a good error message saves.
    """
    lines = [ln.strip() for ln in stderr.splitlines() if ln.strip()]
    errors = [ln for ln in lines if ln.startswith("ERROR:")]
    return (errors[0] if errors else (lines[0] if lines else "no stderr"))[:300]


def live_project_iam(project: str, imp: str | None) -> set[tuple[str, str]]:
    pol = json.loads(_gcloud(["projects", "get-iam-policy", project], imp))
    return {(b["role"], m) for b in pol.get("bindings", []) for m in b.get("members", [])}


# A BigQuery dataset ACL expresses the SAME grant either as a legacy role or as an IAM role,
# depending on which API wrote it. Without this mapping the check reports a correctly-granted
# READER as a missing roles/bigquery.dataViewer — crying wolf on a healthy project, which is
# how a checker gets ignored ([[suspect_the_check_before_the_code]]).
_LEGACY_TO_IAM = {
    "READER": "roles/bigquery.dataViewer",
    "WRITER": "roles/bigquery.dataEditor",
    "OWNER": "roles/bigquery.dataOwner",
}


def live_dataset_iam(project: str, dataset: str, imp: str | None) -> set[tuple[str, str]]:
    """Dataset ACL as {(iam_role, member)}. Raises rather than returning empty on failure —
    a read error must never be indistinguishable from "nothing is granted", or every
    expectation gets reported as missing and the whole run is a false alarm."""
    out = json.loads(_gcloud(["alpha", "bq", "datasets", "describe", dataset, f"--project={project}"], imp))
    have: set[tuple[str, str]] = set()
    for e in out.get("access") or []:
        m = _access_member(e)
        if not m:
            continue
        role = e.get("role", "")
        have.add((_LEGACY_TO_IAM.get(role, role), m))
    return have


def _bare(member: str) -> str:
    """Strip the IAM type prefix. A BigQuery dataset ACL stores a SERVICE ACCOUNT under
    `userByEmail`, with no type information at all, so `serviceAccount:x@y` and `user:x@y`
    denote the same grantee there. Comparing prefixed members reports a correctly-granted
    service account as missing — caught by running this against a project I had just fixed."""
    return member.split(":", 1)[-1] if ":" in member else member


def _access_member(entry: dict) -> str | None:
    for key in ("userByEmail", "groupByEmail", "specialGroup", "iamMember"):
        if key in entry:
            return _bare(entry[key])
    return None


def live_secrets(project: str, imp: str | None) -> set[str]:
    out = json.loads(_gcloud(["secrets", "list", f"--project={project}"], imp) or "[]")
    return {s["name"].rsplit("/", 1)[-1] for s in out}


def live_secret_iam(project: str, secret: str, imp: str | None) -> set[tuple[str, str]]:
    """Raises on failure — the caller turns that into UNVERIFIABLE. Returning an empty set here
    would report every declared grant as missing on a secret we simply could not read."""
    pol = json.loads(_gcloud(["secrets", "get-iam-policy", secret, f"--project={project}"], imp))
    return {(b["role"], m) for b in pol.get("bindings", []) for m in b.get("members", [])}


# ── comparison ─────────────────────────────────────────────────────────────────────

def _why(e: Exception) -> str:
    s = str(e)
    if "PERMISSION_DENIED" in s or "does not have permission" in s or "Access Denied" in s:
        return "permission denied"
    if "not enabled on project" in s:
        return "required API not enabled on the project"
    return s[:120]


def compare(spec: Spec, imp: str | None) -> list[str]:
    """Return a list of failures. Empty means the project matches the declaration.

    ⚠️ EVERY live read is guarded, and a read that fails becomes UNVERIFIABLE rather than a
    traceback or a silent pass. Getting this wrong once (dataset ACLs) taught the lesson;
    applying it to only that one call site was the same mistake at a smaller scale. A crash
    yields no verdict at all, which is worse than a red one — the run looks inconclusive and
    gets retried rather than read.
    """
    failures: list[str] = []
    p = spec.project

    try:
        have_iam = live_project_iam(p, imp)
    except RuntimeError as e:
        # Without the project policy nothing below can be judged, so stop with one clear line
        # rather than emitting a wall of false "missing" findings.
        return [f"UNVERIFIABLE: cannot read {p}'s IAM policy ({_why(e)}) — no parity conclusion "
                f"is possible. Re-run with an identity that can read this project."]
    for role, member in sorted(spec.project_iam):
        if (role, member) not in have_iam:
            failures.append(f"project IAM missing: {role} -> {member}")

    for ds, role, member in sorted(spec.dataset_iam):
        # UNVERIFIABLE is its own outcome, distinct from MISSING. Both mean "parity not
        # established" — so both fail — but they call for different actions: one is a grant to
        # add, the other is an identity that cannot see the resource. Collapsing them would
        # either invent a missing grant or, worse, let an unreadable resource pass silently.
        # (`customer-deployer` holds no dataset access on tenants it did not provision, so
        # this fires for tapps/redwood/jolly/airworks — run those as an IgniteIQ principal.)
        try:
            have_ds = live_dataset_iam(p, ds, imp)
        except RuntimeError as e:
            reason = "permission denied" if "PERMISSION_DENIED" in str(e) or "Access Denied" in str(e) else str(e)[:120]
            failures.append(
                f"UNVERIFIABLE: cannot read dataset '{ds}' ACL ({reason}) — parity for "
                f"{role} -> {member} is unknown, not confirmed. Re-run with an identity that can read it."
            )
            continue
        if (role, _bare(member)) not in have_ds:
            failures.append(f"dataset IAM missing: {ds}: {role} -> {member}")
        # ⚠️ Wider-than-spec is a finding too. A dataset-scoped grant in the module that is
        # held project-wide in reality is a least-privilege regression, and it is invisible to
        # any tenant-to-tenant diff when both tenants share it (measured: eco AND reynolds).
        if (role, member) in have_iam:
            failures.append(
                f"WIDER THAN SPEC: {member} holds {role} at PROJECT level, but the module grants it "
                f"dataset-scoped on '{ds}' only — revoke the project-level binding"
            )

    try:
        have_secrets = live_secrets(p, imp)
    except RuntimeError as e:
        failures.append(f"UNVERIFIABLE: cannot list secrets in {p} ({_why(e)}) — the "
                        f"{len(spec.secrets)} declared secret shell(s) and their grants are unknown, not confirmed.")
        return failures
    for s in sorted(spec.secrets):
        if s not in have_secrets:
            failures.append(f"secret missing: {s} (the Platform SA can add versions but CANNOT create secrets)")

    for secret, role, member in sorted(spec.secret_iam):
        if secret not in have_secrets:
            continue  # already reported as a missing shell
        try:
            have_sec_iam = live_secret_iam(p, secret, imp)
        except RuntimeError as e:
            failures.append(f"UNVERIFIABLE: cannot read {secret}'s IAM policy ({_why(e)}) — "
                            f"parity for {role} -> {member} is unknown, not confirmed.")
            continue
        if (role, member) not in have_sec_iam:
            failures.append(f"secret IAM missing: {secret}: {role} -> {member}")

    return failures


# ── self-test: a checker nobody has watched fail is not evidence ───────────────────

def self_test() -> int:
    """Parse the real .tf files, then assert the comparison catches a planted omission."""
    spec = Spec("acme-igniteiq-data", "acme")
    problems: list[str] = []

    if not spec.project_iam:
        problems.append("parsed no project IAM members from iam.tf")
    if not any("secretVersionAdder" in r for r, _ in spec.project_iam):
        problems.append("did not derive the platform secretVersionAdder grant (gap 3)")
    if sum(1 for r, m in spec.project_iam if "bigquery" in r and "1020933832935-compute" in m) != 3:
        problems.append("did not derive the 3 platform BigQuery grants (gap 4)")
    if not any("dataEditor" in r and "forge-runner" in m for r, m in spec.project_iam):
        problems.append("did not derive forge dataEditor (gap 5)")
    st = {s for s in spec.secrets if "-servicetitan-" in s}
    if st != {f"acme-servicetitan-{f}" for f in ("client-id", "client-secret", "app-key", "tenant-id")}:
        problems.append(f"ST secret shells wrong: {sorted(st)} (gap 2)")
    if not any("secretAccessor" in r and "depot-sa" in m for _, r, m in spec.secret_iam):
        problems.append("did not derive depot-sa secretAccessor on the ST secrets (gap 1)")
    if not any(ds == "ontology" and "dataViewer" in r for ds, r, _ in spec.dataset_iam):
        problems.append("did not derive the dataset-scoped ontology dataViewer grant")

    # Per-environment expansion: one grant per Vault/Forge SA, not one per resource block.
    # Asserted as a COUNT against the variable, so adding a fourth environment cannot leave
    # this check passing on three. The count is the whole point — the string-typed version of
    # these variables derived exactly one member and looked healthy doing it.
    want_vault = len(spec.var_lists.get("igniteiq_vault_sas", []))
    got_vault = sum(1 for ds, r, _ in spec.dataset_iam if ds == "ontology" and "dataViewer" in r)
    if want_vault < 2 or got_vault != want_vault:
        problems.append(f"ontology dataViewer derived for {got_vault} vault SA(s), expected {want_vault}")
    want_forge = len(spec.var_lists.get("igniteiq_forge_sas", []))
    got_forge = sum(1 for r, m in spec.project_iam if "dataEditor" in r and "forge-runner" in m)
    if want_forge < 2 or got_forge != want_forge:
        problems.append(f"forge dataEditor derived for {got_forge} SA(s), expected {want_forge}")

    # Depot v2 is off by default and must contribute nothing: every one of its names
    # carries depot-v2 / depotV2, so one search over everything derived settles it.
    derived = json.dumps([sorted(spec.project_iam), sorted(spec.secrets), sorted(spec.secret_iam), sorted(spec.dataset_iam)])
    if spec.v2_enabled:
        problems.append("depot_v2_enabled defaults to true; the gate check assumes a default of false")
    if "depot-v2" in derived or "depotV2" in derived or "depot_v2" in derived:
        problems.append("derived a Depot v2 grant or secret while depot_v2_enabled is false (ENG-1021 gate)")

    if "${" in json.dumps([sorted(spec.project_iam), sorted(spec.secrets), sorted(spec.dataset_iam)]):
        problems.append("unresolved terraform interpolation left in the derived spec")

    # Each for_each'd secret resolves its OWN key set. Before, every `each.value` id was
    # expanded with the ServiceTitan fields and every for_each'd grant was filtered to
    # "-servicetitan-", so a second credential kind derived wrong ids and no grants, and passed.
    depot_sa = "serviceAccount:depot-sa@acme-igniteiq-data.iam.gserviceaccount.com"
    accessor = "roles/secretmanager.secretAccessor"
    st_iam = {(s, accessor, depot_sa) for s in st}
    if {t for t in spec.secret_iam if "-servicetitan-" in t[0]} != st_iam or len(st_iam) != 4:
        problems.append("depot-sa secretAccessor not derived on exactly the 4 ST shells")
    if "-intacct-" in derived:
        problems.append("derived an Intacct secret or grant by default; intacct_enabled must default to false")
    on = Spec("acme-igniteiq-data", "acme", enable=("intacct_enabled",))
    want_intacct = {f"acme-intacct-{f}" for f in
                    ("sender-id", "sender-password", "company-id", "ws-user-id", "ws-user-password", "entity-id")}
    if on.secrets - spec.secrets != want_intacct:
        problems.append(f"intacct_enabled: shells derived {sorted(on.secrets - spec.secrets)}, expected the 6 Intacct shells")
    if on.secret_iam - spec.secret_iam != {(s, accessor, depot_sa) for s in want_intacct}:
        problems.append(f"intacct_enabled: grants derived {sorted(on.secret_iam - spec.secret_iam)}, "
                        f"expected depot-sa secretAccessor on each of the 6 Intacct shells")
    if (on.project_iam, on.dataset_iam) != (spec.project_iam, spec.dataset_iam) or not spec.secrets <= on.secrets \
            or not spec.secret_iam <= on.secret_iam:
        problems.append("intacct_enabled changed something other than the Intacct shells and their grants")

    # The standalone script for hand-built projects carries its own copy of the field list.
    sh = (REPO / "scripts" / "create_intacct_secret_shells.sh").read_text()
    m = re.search(r"^FIELDS=\((.*?)\)$", sh, re.M)
    sh_fields = m.group(1).split() if m else []
    if sh_fields != _list_local(spec.locals_src, "intacct_secret_fields"):
        problems.append(f"create_intacct_secret_shells.sh FIELDS {sh_fields} != local.intacct_secret_fields")

    # Fail closed: a for_each it cannot follow must raise, not derive a smaller spec.
    for label, old, new in (
        ("unknown secret resource", "for_each  = google_secret_manager_secret.intacct",
         "for_each  = google_secret_manager_secret.nonexistent"),
        ("unknown field local", "toset(local.intacct_secret_fields)", "toset(local.nonexistent_fields)"),
    ):
        with tempfile.TemporaryDirectory() as tmp:
            for f in ("iam.tf", "secrets.tf", "variables.tf", "locals.tf"):
                shutil.copy(REPO / f, tmp)
            sec = Path(tmp, "secrets.tf")
            if old not in sec.read_text():
                problems.append(f"fail-closed fixture is stale ({label}): `{old}` is no longer in secrets.tf")
                continue
            sec.write_text(sec.read_text().replace(old, new))
            try:
                Spec("acme-igniteiq-data", "acme", root=Path(tmp), enable=("intacct_enabled",))
                problems.append(f"fail-closed: {label} derived a spec instead of raising")
            except RuntimeError:
                pass

    # Negative test: drop one expectation and confirm the comparison would flag it.
    planted = ("roles/bigquery.jobUser", "serviceAccount:1020933832935-compute@developer.gserviceaccount.com")
    if planted not in spec.project_iam:
        problems.append("planted-omission fixture is stale — that grant is no longer in iam.tf")

    if problems:
        print("self-test FAIL:")
        for p in problems:
            print(f"  - {p}")
        return 1

    print(f"self-test PASS — derived {len(spec.project_iam)} project IAM, {len(spec.dataset_iam)} dataset IAM, "
          f"{len(spec.secrets)} secrets, {len(spec.secret_iam)} secret IAM from the .tf files, all five Eco gaps covered; "
          f"intacct_enabled adds {len(on.secrets - spec.secrets)} shells and {len(on.secret_iam - spec.secret_iam)} grants.")
    return 0


def _split_accepted(failures: list[str], project: str) -> tuple[list[str], list[tuple[str, dict]]]:
    """Partition failures into (still-failing, accepted). Missing/malformed exceptions file =>
    nothing is accepted, i.e. it fails closed. An unreadable allowlist must never widen what
    passes ([[gate_may_not_be_on_every_path]])."""
    path = REPO / "parity-exceptions.json"
    try:
        exceptions = json.loads(path.read_text()).get("exceptions", [])
    except Exception:
        return failures, []

    still, ok = [], []
    for f in failures:
        for exc in exceptions:
            match = exc.get("match", "")
            projects = exc.get("projects") or []
            # An exception with no reason is indistinguishable from a bug someone gave up on,
            # so it does not count as accepted.
            if match and match in f and project in projects and exc.get("reason"):
                ok.append((f, exc))
                break
        else:
            still.append(f)
    return still, ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project")
    ap.add_argument("--slug")
    ap.add_argument("--impersonate", default="customer-deployer@igniteiq-dev.iam.gserviceaccount.com")
    ap.add_argument("--enable", action="append", default=[], metavar="VAR",
                    help="a bool variable this tenant's tfvars set to true, e.g. --enable intacct_enabled")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()

    if a.self_test:
        return self_test()
    if not (a.project and a.slug):
        ap.error("--project and --slug are required (or use --self-test)")

    spec = Spec(a.project, a.slug, enable=tuple(a.enable))
    print(f"Comparing {a.project} (slug={a.slug}) against the terraform declaration in {REPO.name}/\n")
    all_failures = compare(spec, a.impersonate or None)
    failures, accepted = _split_accepted(all_failures, a.project)

    # Accepted items are PRINTED, never hidden. A check that can only ever be red trains people
    # to ignore it; a check that can be silenced gets used to bury things. Showing the exception
    # with its reason is the honest middle — the finding stays visible, it just stops gating.
    for f, exc in accepted:
        print(f"  ACCEPTED  {f}")
        print(f"            └─ {exc['reason'][:200]}")
        print(f"            └─ accepted by {exc.get('accepted_by', '?')}\n")

    if not failures:
        extra = f", {len(accepted)} accepted exception(s)" if accepted else ""
        print(f"PASS — {a.project} matches the declaration{extra} "
              f"({len(spec.project_iam)} project IAM, {len(spec.dataset_iam)} dataset IAM, "
              f"{len(spec.secrets)} secrets, {len(spec.secret_iam)} secret IAM).")
        return 0

    print(f"FAIL — {len(failures)} difference(s) between {a.project} and the declaration:\n")
    for f in failures:
        print(f"  - {f}")
    print("\nEvery item above is something the self-serve terraform would have created. Fix them,\n"
          "then record this check's output in the customer's onboarding-status.md.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
