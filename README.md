# Paddock

[![CI](https://github.com/JoachimC/terraform-aws-paddock/actions/workflows/ci.yml/badge.svg)](https://github.com/JoachimC/terraform-aws-paddock/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)
[![Terraform and OpenTofu](https://img.shields.io/badge/Terraform%20%7C%20OpenTofu-%E2%89%A5%201.10-844fba.svg)](#requirements)
[![Open Source Maintenance Fee](https://img.shields.io/badge/Open%20Source-Maintenance%20Fee-blue)](#open-source-maintenance-fee)

Paddock sets up one AWS account so that several small projects can share it.
Each project, a **paddock**, gets its own deploy role, plan role, runtime
roles, Terraform state and hostname. The project's own Terraform then builds,
changes and tears down everything else, from GitHub Actions, with no access
keys.

It is for small projects where a separate AWS account per project is more
work than it is worth. The separation stops mistakes crossing from one
project to another. It is not a wall against an attacker; see
[`SECURITY.md`](SECURITY.md).

## How it works

```
account layer (an admin applies it by hand)
├── state bucket        one key prefix per paddock
├── GitHub OIDC provider
├── hosted zone         e.g. apps.example.com
└── wildcard cert       *.apps.example.com

paddock "orders" (created by the same admin run)
├── orders-deploy       GitHub OIDC, main branch of one repo
├── orders-plan         GitHub OIDC, pull requests of that repo, read-only
├── orders-app          runtime role for Lambda, capped by orders-boundary
└── state prefix        orders/

the orders repo's own Terraform (CI, as orders-deploy)
└── Lambda, REST API, custom domain, DNS record, tables, secrets …
    all named orders-* or tagged Paddock = orders
```

* **The deploy role is scoped by name and tag.** It may manage resources
  whose name starts with the paddock name, in the AWS services the paddock
  chose. For services that assign ids (API Gateway, KMS) it must tag each
  resource `Paddock = <name>` at creation, and may later touch only what
  carries that tag. It may never tag a resource for another paddock.
* **The deploy role cannot escape through IAM.** It cannot create a role,
  change a role's trust, or touch a permissions boundary. It may write inline
  policies on its own runtime roles, and the boundary caps them at the
  paddock's own resources.
* **State is separated by prefix.** Each deploy role and plan role reaches
  only its own prefix in the state bucket. The bucket policy keeps every
  other principal out, and no paddock can reach the account layer's state.
* **DNS is separated by name.** A paddock may change only the records for its
  own hostnames. One wildcard certificate covers every hostname, so the
  hostnames stay out of Certificate Transparency logs.

The design and the reasons behind each choice are in
[`docs/design.md`](docs/design.md).

## Requirements

* Terraform 1.10 or later, or OpenTofu 1.10 or later. CI checks both.
* AWS provider 6.0 or later.
* The AWS CLI, for `scripts/paddock-init.sh`.
* GitHub Actions for each paddock's CI.

## Quickstart

### 1. The account root

Keep one central repository for the account. Copy
[`examples/account-root`](examples/account-root) into it, and point the
module sources at a release:

```hcl
module "account" {
  source = "git::https://github.com/JoachimC/terraform-aws-paddock.git//modules/account?ref=v0.1.0"
  # …
}

module "paddock" {
  source   = "git::https://github.com/JoachimC/terraform-aws-paddock.git//modules/paddock?ref=v0.1.0"
  for_each = var.paddocks
  # …
}
```

Copy `example.tfvars` to `account.tfvars` and fill it in: the bucket
prefix, your admin ARN, the domain, and one entry per service.

### 2. Apply it

Sign in as an admin, then run the script from the account root:

```bash
aws login --profile admin
export AWS_PROFILE=admin
path/to/terraform-aws-paddock/scripts/paddock-init.sh account.tfvars
```

The first run uses your default region. It keeps state on your machine,
creates the state bucket, then moves the state into the bucket. Every later
run reads the region and the state from the bucket. Run the script again
whenever you add a paddock or change one.

At the end, the script prints a `gh variable set` command for each variable
of each paddock repository. Run them.

### 3. Each service

Copy [`examples/service`](examples/service) into the service's repository as
a starting point, and `deploy.yml` into `.github/workflows/`. A pull request
then plans with the plan role, and a push to `main` applies with the deploy
role.

Two rules the service's Terraform must follow:

* Set `default_tags { tags = { Paddock = "<name>" } }` on the AWS provider.
  The deploy role refuses to create a tagged resource without it.
* Name every resource as the table below says.

| Service | Name or tag rule |
|---|---|
| `lambda` | functions and layers `<name>-*` |
| `logs` | log groups `/aws/lambda/<name>-*`, `/aws/apigateway/<name>-*`, `/paddock/<name>/*` |
| `dynamodb` | tables `<name>-*` |
| `s3` | buckets `<name>-*` (add the account id: bucket names are global) |
| `sqs`, `sns` | queues and topics `<name>-*` |
| `secretsmanager` | secrets `<name>/*`; secrets for other paddocks `<name>/shared/*` |
| `ssm` | parameters `/<name>/*`; public values `/<name>/public/*` |
| `ecr` | repositories `<name>-*` |
| `events` | rules `<name>-*` on the default bus |
| `cloudwatch` | alarms `<name>-*` |
| `apigateway` | REST APIs tagged `Paddock = <name>`; custom domains for the paddock's `hostnames` |
| `kms` | keys tagged `Paddock = <name>`; aliases `alias/<name>-*` |

What the service needs from the account (region, zone id, certificate ARN,
admins) is published under `/account/public/` in SSM Parameter Store.

## Modules

| Module | What it creates |
|---|---|
| [`modules/account`](modules/account) | State bucket and its policy, GitHub OIDC provider, account-wide S3 public access block, hosted zone and its delegation, wildcard certificate, `/account/public/*` parameters. Optional: the `Paddock` cost allocation tag, the API Gateway CloudWatch role. |
| [`modules/paddock`](modules/paddock) | Deploy role, plan role, runtime roles and their boundary, and a monthly budget on the `Paddock` tag. |
| [`modules/data-guard`](modules/data-guard) | Deny statements for a resource policy, so that only the paddock's runtime roles use the data and only its CI roles manage the resource. For a service's own Terraform. |

Each module's variables carry their own descriptions.

## Sharing between paddocks

Every resource has one owner paddock. Avoid sharing where you can:

* **Public values** (endpoint URLs, client ids, public keys): the owner writes
  them under `/<owner>/public/` in SSM. A paddock that lists the owner in
  `reads_from` may read them.
* **Token signing keys**: use asymmetric keys, and publish the public key at a
  JWKS URL. Then nothing in AWS is shared.
* **Secrets**, only when there is no other way: the owner names the secret
  `<owner>/shared/*` and grants the reader's runtime role in the secret's
  resource policy. The reader lists the owner in `reads_from`. Use the default
  `aws/secretsmanager` key; a reader cannot use the owner's own KMS key.

## Teardown

1. Destroy each service from its own repository, with its deploy role.
2. Remove the paddock from `account.tfvars` and run the script. This deletes
   its roles. Done in the other order, only an admin can clean up.
3. To remove the account layer, only after every paddock is gone: move the
   state out of the bucket (write `paddock_backend_override.tf` as the script
   does, then `terraform init -migrate-state`), remove `prevent_destroy` from
   the state bucket, empty the bucket including every version, then
   `terraform destroy`.

## Recovery

* **A run stops with a state lock.** A cancelled run leaves the lock object
  beside the state. Clear it with `terraform force-unlock <id>` once nothing
  else runs.
* **The first run fails at "Phase 2" with `AccessDenied`.** The bucket policy
  does not list your ARN: `admin_principal_arns` is wrong. Fix it and run the
  script again. It finds the local state and finishes the move.
* **The bucket exists, but no state does, anywhere.** Import the existing
  resources into a new state with `import` blocks, or delete them and start
  again.
* **The first run fails on the API Gateway service-linked role with
  `InvalidInput` (it already exists).** The account had it before. Set
  `create_api_gateway_service_linked_role = false`, or import it with an
  `import` block to `module.account.aws_iam_service_linked_role.api_gateway[0]`.
* **A bad apply.** The bucket keeps old versions of every state file for
  `noncurrent_state_version_days`. Restore an earlier version with
  `aws s3api copy-object`.

## Development

```bash
scripts/check.sh
```

The script runs fmt, validate and test with Terraform and OpenTofu, in
their official Docker images. It needs only Docker. The tests use a mock
provider and need no AWS account. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Contributing

Issues and pull requests are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md)
for the workflow (one branch and pull request per issue,
`given_…_when_…_then_…` test names, both tools must pass) and
[`SECURITY.md`](SECURITY.md) for the threat model and how to report a
vulnerability.

## Open Source Maintenance Fee

This project participates in the [Open Source Maintenance Fee](https://opensourcemaintenancefee.org). The source code is freely available under the terms of the [License](#license) below. To support sustainable maintenance, use of the project's official releases in revenue-generating activities requires adherence to the [Open Source Maintenance Fee](./OSMFEULA.txt).

In practice: if you run your own personal projects on it, you owe
nothing. If you use this project's official releases (the tagged versions on
GitHub and in the Terraform and OpenTofu registries) as part of
revenue-generating activities, and your annual gross revenue is US$10,000 or
more, the Maintenance Fee applies. It is a small monthly sponsorship, not a
licence fee: the code stays MIT OR Apache-2.0, and you remain free to use
your own copy of the source.

To pay the Maintenance Fee, [become a Sponsor](https://github.com/sponsors/JoachimC).

## License

Licensed under either of

* Apache License, Version 2.0 (`LICENSE-APACHE` or <http://www.apache.org/licenses/LICENSE-2.0>)
* MIT license (`LICENSE-MIT` or <http://opensource.org/licenses/MIT>)

at your option. Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
