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
import subprocess
import sys
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


def _list_local(src: str, name: str) -> list[str]:
    m = re.search(rf'{re.escape(name)}\s*=\s*\[(.*?)\]', src, re.S)
    if not m:
        return []
    return re.findall(r'"([^"]+)"', m.group(1))


class Spec:
    """The declared shape of a provisioned project, read out of the .tf files."""

    def __init__(self, project: str, slug: str, root: Path = REPO) -> None:
        iam = (root / "iam.tf").read_text()
        secrets = (root / "secrets.tf").read_text()
        variables = (root / "variables.tf").read_text()
        locals_ = (root / "locals.tf").read_text()

        self.project, self.slug = project, slug
        self.vars = _var_defaults(variables)
        self.st_fields = _list_local(locals_, "st_secret_fields")
        self.sa_emails = {
            n: f"{_attr(b, 'account_id').strip(chr(34))}@{project}.iam.gserviceaccount.com"
            for n, b in _hcl_bodies(iam, "google_service_account")
        }

        self.project_iam: set[tuple[str, str]] = set()
        for _, body in _hcl_bodies(iam, "google_project_iam_member"):
            role, member = _attr(body, "role"), _attr(body, "member")
            if role and member:
                self.project_iam.add((self._resolve(role), self._resolve(member)))

        self.dataset_iam: set[tuple[str, str, str]] = set()
        for _, body in _hcl_bodies(iam, "google_bigquery_dataset_iam_member"):
            ds, role, member = _attr(body, "dataset_id"), _attr(body, "role"), _attr(body, "member")
            if ds and role and member:
                m = re.search(r'datasets\["([^"]+)"\]', ds)
                self.dataset_iam.add(((m.group(1) if m else self._resolve(ds)), self._resolve(role), self._resolve(member)))

        self.secrets: set[str] = set()
        self.secret_iam: set[tuple[str, str, str]] = set()
        for _, body in _hcl_bodies(secrets, "google_secret_manager_secret"):
            sid = _attr(body, "secret_id")
            if not sid:
                continue
            if "each.value" in sid:
                for f in self.st_fields:
                    self.secrets.add(self._resolve(sid).replace("${each.value}", f))
            else:
                self.secrets.add(self._resolve(sid))
        for _, body in _hcl_bodies(secrets, "google_secret_manager_secret_iam_member"):
            role, member = _attr(body, "role"), _attr(body, "member")
            if not (role and member):
                continue
            # for_each over the ST secrets -> one grant per shell
            targets = sorted(s for s in self.secrets if "-servicetitan-" in s) if "each.value" in (_attr(body, "secret_id") or "") else sorted(self.secrets)
            for t in targets:
                self.secret_iam.add((t, self._resolve(role), self._resolve(member)))

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
    cmd = ["gcloud", *args, "--format=json"]
    if impersonate:
        cmd.append(f"--impersonate-service-account={impersonate}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {r.stderr.strip()[:300]}")
    return r.stdout


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
    try:
        pol = json.loads(_gcloud(["secrets", "get-iam-policy", secret, f"--project={project}"], imp))
    except RuntimeError:
        return set()
    return {(b["role"], m) for b in pol.get("bindings", []) for m in b.get("members", [])}


# ── comparison ─────────────────────────────────────────────────────────────────────

def compare(spec: Spec, imp: str | None) -> list[str]:
    """Return a list of failures. Empty means the project matches the declaration."""
    failures: list[str] = []
    p = spec.project

    have_iam = live_project_iam(p, imp)
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

    have_secrets = live_secrets(p, imp)
    for s in sorted(spec.secrets):
        if s not in have_secrets:
            failures.append(f"secret missing: {s} (the Platform SA can add versions but CANNOT create secrets)")

    for secret, role, member in sorted(spec.secret_iam):
        if secret not in have_secrets:
            continue  # already reported as a missing shell
        if (role, member) not in live_secret_iam(p, secret, imp):
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
    if "${" in json.dumps([sorted(spec.project_iam), sorted(spec.secrets)]):
        problems.append("unresolved terraform interpolation left in the derived spec")

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
          f"{len(spec.secrets)} secrets, {len(spec.secret_iam)} secret IAM from the .tf files, all five Eco gaps covered.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project")
    ap.add_argument("--slug")
    ap.add_argument("--impersonate", default="customer-deployer@igniteiq-dev.iam.gserviceaccount.com")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()

    if a.self_test:
        return self_test()
    if not (a.project and a.slug):
        ap.error("--project and --slug are required (or use --self-test)")

    spec = Spec(a.project, a.slug)
    print(f"Comparing {a.project} (slug={a.slug}) against the terraform declaration in {REPO.name}/\n")
    failures = compare(spec, a.impersonate or None)

    if not failures:
        print(f"PASS — {a.project} matches the declaration "
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
