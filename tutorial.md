# Deploy IgniteIQ into your Google Cloud project

This Cloud Shell tutorial provisions the IgniteIQ **Depot** data stack inside
**your own** GCP project. You run it as yourself — IgniteIQ never receives your
Google credentials.

## Before you start
- Your business has a **Google Cloud Organization** (via Google Workspace or free
  [Cloud Identity](https://cloud.google.com/identity/docs/set-up-cloud-identity-admin)),
  and the target project lives **under that org**. A standalone project owned by a
  personal `@gmail.com` account will not work — Google blocks the admin operations
  this deploy needs. Cloud Identity is free and does not affect your existing email.
- You are an **Owner** (or Editor + Project IAM Admin) of the target project, signed
  in as an **organization account** (e.g. `you@yourcompany.com`, not a personal Gmail).
- **Billing is enabled** on the project.
- If your org enforces **Domain restricted sharing** (`iam.allowedPolicyMemberDomains`),
  allowlist IgniteIQ's customer ID **`C0178jm4f`** on this project (Console → IAM &
  Admin → Organization Policies), or the deploy can't grant IgniteIQ's service
  accounts access. The deploy checks this first and tells you.
- The Studio onboarding wizard gave you a **one-time setup code**.

## Deploy
Paste the one-time code the wizard showed you:
```bash
bash scripts/deploy.sh <your-code>
```
This one command:
1. downloads your settings (`terraform.tfvars`: your project ID and a short-lived
   provisioning token) over HTTPS;
2. checks your project is ready — organization, billing, sharing policy, network —
   and stops with instructions if something needs fixing first;
3. creates a small storage bucket in **your** project to hold Terraform state;
4. installs Terraform if Cloud Shell does not have it;
5. shows you every resource it is about to create in your project.

Review the list, then type `yes` to confirm. The deploy takes **15–20 minutes**
(most of it is the cluster coming up). When it finishes, return to the IgniteIQ
Studio tab — it detects completion automatically and walks you through
connecting your data.

## If something fails
Fix what the message describes, then run the command again without the code:
```bash
bash scripts/deploy.sh
```
It is safe to repeat; it continues where it left off. If the message says your
provisioning token was rejected, get a new code from the Studio wizard and run
`bash scripts/deploy.sh <new-code>`.

Still stuck? Copy the error and contact IgniteIQ support.
