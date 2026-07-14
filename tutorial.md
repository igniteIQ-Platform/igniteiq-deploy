# Deploy IgniteIQ into your Google Cloud project

This Cloud Shell tutorial provisions the IgniteIQ **Depot** data stack inside
**your own** GCP project. You run every step as yourself — IgniteIQ never
receives your Google credentials.

## Before you start
- You are an **Owner** (or Editor + Project IAM Admin) of the target project.
- **Billing is enabled** on the project.
- The Studio onboarding wizard gave you a **one-time setup code**.

## Step 1 — Fetch your settings
Paste the one-time code the wizard showed you:
```bash
bash scripts/fetch_config.sh <your-code>
```
This securely downloads your `terraform.tfvars` (project ID + a short-lived
provisioning token) over HTTPS. Then confirm it:
```bash
cat terraform.tfvars
```
Check `project_id`. Everything else was filled in by the wizard.

## Step 2 — Prepare Terraform state
```bash
bash scripts/bootstrap_state.sh
```
This creates a small storage bucket in **your** project to hold Terraform state,
then wires it up.

## Step 3 — Make sure Terraform is installed
Cloud Shell usually includes Terraform, but not always. This checks and installs
it if needed (takes ~30 seconds the first time, instant otherwise):
```bash
bash scripts/ensure_terraform.sh
```

## Step 4 — Initialize
```bash
terraform init
```

## Step 5 — Review
```bash
terraform plan
```
You'll see the resources that will be created in your project.

## Step 6 — Deploy
```bash
terraform apply
```
Type `yes` to confirm. This takes **15–20 minutes** (most of it is the cluster
coming up). When it finishes, return to the IgniteIQ Studio tab — it will detect
completion automatically and walk you through connecting ServiceTitan.

## If something fails
Re-run `terraform apply` — it's safe to retry; it continues where it left off.
Still stuck? Copy the error and contact IgniteIQ support.
