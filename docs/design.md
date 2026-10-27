# Design

Paddock lets several small projects share one AWS account, with every
resource in Terraform, each project easy to change and to tear down, and
mistakes kept inside the project that made them. This page records each
decision, its trade-off, and when to revisit it.

## Goals and non-goals

Goals:

* Every resource of a service is in Terraform: in the account root, or in the
  service's own repository.
* Each service can change, redeploy and be destroyed without touching any
  other service.
* CI deploys with a short-lived identity from GitHub OIDC. No access keys
  exist.
* Each service's data is used only by that service's identities and the
  named admins.
* No resources are shared between services, except where one paddock owns
  the resource and grants another.

Non-goals:

* One AWS account per workload. AWS Organizations is more work than it is
  worth at this scale.
* Protection against an attacker who controls a deploy role. The separation
  stops mistakes.
* Hiding services. Auth on every endpoint is the real control.

## One account, separated by name and tag

**Decision.** All paddocks share one account. Each deploy role may manage
only resources whose name starts with the paddock name, or that carry the
tag `Paddock = <name>` where AWS assigns the id.

**Trade-off.** An account is the only boundary that IAM mistakes cannot leak
through; names and tags are weaker. In return there is no AWS Organizations,
no account per project, no cross-account DNS or certificates.

**Revisit when** a workload needs a hard wall, its own quotas, or its own
bill without tags.

## Whole service families, not single actions

**Decision.** The deploy role gets `service:*` on the paddock's own
resources, for the services listed in `aws_services`.

**Trade-off.** A list of single actions (as in an earlier project) is
tighter, but every new resource type needs an admin run of the account root.
Scoping by name keeps the blast radius at the paddock while letting the
service grow on its own.

**Revisit when** a service family holds an action that reaches outside the
named resource. Name that action in a Deny.

## The deploy role cannot create roles

**Decision.** The account root creates each paddock's runtime roles and fixes
a permissions boundary on them. The deploy role may write inline policies on
those roles and pass them to Lambda. It may not create a role, change a
trust policy, or change a boundary; a Deny says so explicitly.

**Trade-off.** A new runtime role needs an admin run. Without this rule, a
deploy role that may create roles can create one with `"Action": "*"` and an
outside trust, and so become account admin. That gap existed in the earlier
project this design comes from.

## State: one bucket, one prefix per paddock

**Decision.** One versioned bucket, `<prefix>-terraform-state-<account id>`,
with S3 native locking. Each CI role reaches only `<paddock>/`. Deploy and
plan roles sit under the IAM path `/paddock/ci/`, so the bucket policy names
all of them with one pattern and never changes when a paddock is added. The
policy holds only Deny statements and never denies bucket-policy actions, so
a wrong admin pattern locks nobody out of fixing it.

**The first run.** The account root creates the bucket that will hold its
own state. `paddock-init.sh` applies once with local state, then moves the
state into the bucket. Later runs read the region from the bucket's location,
so a second admin with another default region cannot split the account.

## Plan on pull requests

**Decision.** Each paddock gets a read-only plan role, trusted by
`pull_request` tokens of its repository. It reads state and resources, and
may write only the lock object.

**Trade-off.** Plans on pull requests catch mistakes before main. The plan
role can read state, which can hold secrets; for a public repository, pull
requests from branches in the repository get an OIDC token. It does not get
`secretsmanager:GetSecretValue`: set secret values outside Terraform.

## Hostnames, DNS and certificates

**Decision.** Each paddock serves its own hostname, one level under one
domain (for example `api.apps.example.com`), from its own Regional REST
API. The account root owns the zone and one wildcard certificate. A paddock
may change DNS records for its own hostnames only.

**Why a hostname per paddock, not one host with paths.** Each paddock then
owns its whole stack, with no shared API front. OAuth and MCP discovery
documents sit at each host's root, and cookies stay on their own host.

**Why one wildcard certificate.** Certificate Transparency logs publish every
name on a public certificate. A certificate per paddock would publish the
list of services; a wildcard publishes only `*.apps.example.com`. ACM
certificates for AWS services are free, so cost does not decide this.

**Why a REST API, not an HTTP API.** Only REST APIs can stream a response,
and only REST API child resources inherit the API's tags for access checks.

## Data: manage versus use

**Decision.** `modules/data-guard` writes two Deny statements for a resource
policy: only the runtime roles and admins use the data; only the deploy
role, the plan role and admins manage the resource.

**Why a Deny.** Within one account, AWS allows a request when either the
identity policy or the resource policy allows it. An Allow alone does not
stop another role that has `dynamodb:*` on `*` by mistake.

## Sharing

**Decision.** Every resource has one owner. Public values go under
`/<owner>/public/` in SSM, readable by paddocks that list the owner in
`reads_from`. A shared secret needs two steps on purpose: the owner's
resource policy grants the reader, and the reader's `reads_from` widens its
boundary.

## Budgets

**Decision.** Each paddock can have a monthly budget filtered on its
`Paddock` tag. The tag must be an active cost allocation tag first, which AWS
allows only once the tag shows in billing data.

## Terraform and OpenTofu

**Decision.** Support both, from Terraform 1.10 and OpenTofu 1.10, the first
versions with S3 native locking. The modules use only what both tools share:
no OpenTofu backend variables or state encryption, no Terraform-only
features. CI runs every check with both, at the oldest and the newest
version.

**Revisit when** a feature that only one tool has removes real work from the
account root, for example backend variables in place of `-backend-config`.

## Naming

| Thing | Name |
|---|---|
| Deploy role | `/paddock/ci/<name>-deploy` |
| Plan role | `/paddock/ci/<name>-plan` |
| Runtime role | `/paddock/runtime/<name>-<role>` |
| Boundary | `/paddock/<name>-boundary` |
| State key | `<name>/terraform.tfstate` |
| Account state key | `account/terraform.tfstate` |
| Tag | `Paddock = <name>` |
| Public parameters | `/account/public/*`, `/<name>/public/*` |
| Repository variables | `PADDOCK`, `AWS_REGION`, `TF_STATE_BUCKET`, `TF_STATE_KEY`, `AWS_DEPLOY_ROLE_ARN`, `AWS_PLAN_ROLE_ARN` |
