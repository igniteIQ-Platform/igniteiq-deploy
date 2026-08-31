#!/usr/bin/env python3
"""Does the Terraform a CUSTOMER runs still expect the artifact names we publish?

This module executes in the customer's own GCP project, as the customer. It does not build
or copy anything — it expects three OCI artifacts to ALREADY BE THERE, under exact names,
put there by igniteiq-platform's connector-push callback from artifacts igniteiq-depot
published. Three repos hold one set of names and nothing joins them.

🔴 THIS IS THE END OF THE CHAIN WHERE A MISMATCH COSTS MOST. A rename in either of the other
two repos does not fail their build, their review, or their plan. It fails here, during a new
customer's onboarding, in a project we cannot reproduce, as `terraform apply` referencing an
image that is not there.

contracts/depot-artifacts.json is the agreed set of names, byte-identical in all three repos.

  python3 scripts/check_artifact_contract.py --self-test
  python3 scripts/check_artifact_contract.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "contracts" / "depot-artifacts.json"


def tf_local(text: str, name: str):
    m = re.search(rf'^\s*{name}\s*=\s*"([^"]*)"\s*$', text, re.M)
    return m.group(1) if m else None


def tf_var_default(text: str, name: str):
    """The default of `variable "<name>" { ... default = "..." }`."""
    m = re.search(rf'variable\s+"{name}"\s*\{{(.*?)^\}}', text, re.S | re.M)
    if not m:
        return None
    d = re.search(r'^\s*default\s*=\s*"([^"]*)"\s*$', m.group(1), re.M)
    return d.group(1) if d else None


def check(root: Path, c: dict) -> list[str]:
    bad: list[str] = []
    target = c["target"]

    locals_tf = root / "locals.tf"
    vars_tf = root / "variables.tf"
    for p in (locals_tf, vars_tf):
        if not p.exists():
            bad.append(f"{p.name} does not exist — cannot verify the customer's expectations")
    if bad:
        return bad

    lt, vt = locals_tf.read_text(), vars_tf.read_text()

    got = tf_local(lt, "connector_repo")
    if got != target["repo"]:
        bad.append(
            f"locals.tf connector_repo is {got!r}, contract expects {target['repo']!r}\n"
            f"    This is the repo in the CUSTOMER's project that both the image and the chart\n"
            f"    are copied into. Our side splits them across two repos; here they share one."
        )

    got = tf_var_default(vt, "connector_image_name")
    if got != target["connector_image_name"]:
        bad.append(
            f"variables.tf connector_image_name default is {got!r}, contract expects "
            f"{target['connector_image_name']!r}\n"
            f"    ⚠️ Not the same string as the manifest slug ({c['connector']['manifest_slug']!r}),\n"
            f"    and deliberately so. Do not 'fix' one to match the other."
        )

    got = tf_var_default(vt, "depot_chart_name")
    if got != target["chart_name"]:
        bad.append(
            f"variables.tf depot_chart_name default is {got!r}, contract expects "
            f"{target['chart_name']!r}\n"
            f"    Must equal `name:` in igniteiq-depot charts/{target['chart_name']}/Chart.yaml."
        )

    # The chart reference must be built from the same repo local, not a second literal.
    ref = tf_local(lt, "chart_oci_ref")
    if ref is None:
        bad.append("locals.tf has no chart_oci_ref")
    elif "local.connector_repo" not in ref:
        bad.append(
            f"locals.tf chart_oci_ref does not interpolate local.connector_repo: {ref!r}\n"
            f"    A second literal for the same repository is how the two stop matching."
        )
    return bad


def self_test() -> int:
    import tempfile

    fails: list[str] = []
    c = {
        "target": {"repo": "depot-connectors", "connector_image_name": "servicetitan",
                   "chart_name": "depot-ingest"},
        "connector": {"manifest_slug": "source-servicetitan"},
    }

    def build(tmp: Path, repo="depot-connectors", image="servicetitan",
              chart="depot-ingest", ref='oci://${local.connector_repo}/x'):
        (tmp / "locals.tf").write_text(
            f'locals {{\n  connector_repo  = "{repo}"\n  chart_oci_ref   = "{ref}"\n}}\n')
        (tmp / "variables.tf").write_text(
            f'variable "connector_image_name" {{\n  type = string\n  default     = "{image}"\n}}\n'
            f'variable "depot_chart_name" {{\n  type = string\n  default     = "{chart}"\n}}\n')

    def run(**kw):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            build(tmp, **kw)
            return check(tmp, c)

    def expect(got, want_fail, what):
        if bool(got) != want_fail:
            fails.append(f"{what}: {'expected a failure' if want_fail else 'expected clean, got ' + str(got)}")

    expect(run(), False, "a consistent module passes")
    expect(run(repo="other"), True, "a renamed target repo fails")
    expect(run(image="source-servicetitan"), True, "using the manifest slug as the image name fails")
    expect(run(chart="other"), True, "a renamed chart fails")
    # The one that is easy to write and wrong: a hardcoded second copy of the repo name.
    expect(run(ref="oci://us-central1-docker.pkg.dev/p/depot-connectors/x"), True,
           "a chart_oci_ref with a hardcoded repo fails even when the string is currently right")

    with tempfile.TemporaryDirectory() as d:
        if not check(Path(d), c):
            fails.append("an EMPTY module passed — absent files must not read as clean")

    if fails:
        print("self-test FAIL:", file=sys.stderr)
        for f in fails:
            print("  - " + f, file=sys.stderr)
        return 1
    print("self-test OK — each name fails independently, a hardcoded repo fails even while "
          "correct, and an empty module fails rather than passing vacuously")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    if not CONTRACT.exists():
        print(f"::error::{CONTRACT} is missing. It is byte-identical in igniteiq-platform, "
              f"igniteiq-depot and igniteiq-deploy; copy it from one of those.")
        return 1
    # Print the contract's fingerprint. Nothing cross-repo compares the three copies — the
    # "byte-identical in N repos" pattern has no owner anywhere in this fleet — so the cheapest
    # real check is that all three CI logs show the same digest. If they differ, one repo is
    # checking itself against a contract the others have not agreed to.
    import hashlib
    print(f"contract sha256: {hashlib.sha256(CONTRACT.read_bytes()).hexdigest()[:16]}  ({CONTRACT.name})")
    bad = check(ROOT, json.loads(CONTRACT.read_text()))
    if bad:
        print("::error::this module expects artifact names that no longer match the contract:")
        for b in bad:
            print("  - " + b)
        return 1
    print("customer-side artifact contract OK — repo, image name, chart name and the OCI ref agree.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
