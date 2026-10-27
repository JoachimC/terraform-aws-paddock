# Security

## Threat model

Paddock is designed for **small projects that share one AWS account**, all
run by people who trust each other. It assumes these conditions:

* The administrators named in `admin_principal_arns` own the account. They
  apply the account root by hand, with credentials that only they hold.
* Each service's repository is trusted by its maintainers. Anyone who can
  push to the deploy branch can do anything that the paddock's deploy role
  allows.
* The separation between paddocks exists to stop **mistakes** crossing from
  one service to another. It is not a wall against an attacker who already
  controls a deploy role.

Know these limits before you rely on the separation:

* **A deploy role controls its whole paddock.** It can read, change and
  delete every resource named or tagged for the paddock, and give the
  paddock's runtime roles any right inside the boundary.
* **A runtime role is only as narrow as the inline policy that its paddock
  writes.** The boundary caps it at the paddock's own resources, not at what
  the function needs.
* **The plan role reads the paddock's state.** State can hold secret values.
  Anyone who can open a pull request in the paddock's repository can run a
  workflow with the plan role. For a public repository, GitHub gives a pull
  request from a fork no OIDC token, but a pull request from a branch in the
  repository gets one.
* **List and describe actions are account-wide** where AWS gives them no
  resource (for example `lambda:ListFunctions`). A paddock can see the names
  of other paddocks' resources, not their contents.
* **The tag guard covers the services in `aws_services`.** AWS evaluates
  tag conditions per service and per action; an action that ignores
  `aws:RequestTag` or `aws:TagKeys` is not caught.
* **HTTP APIs (API Gateway v2) are not scoped.** Only REST APIs inherit the
  API's tags for access checks, so `apigateway` covers REST APIs only.
* **One account is still one account.** Account-wide quotas, such as Lambda
  concurrency, are shared. For a hard wall between workloads, use separate
  AWS accounts.

## Report a vulnerability

Do **not** open a public issue for a problem that an attacker can use, such
as a way for a deploy role to act outside its paddock.

1. Go to the **Security** tab of this repository.
2. Select **Report a vulnerability**. This sends a private report.
3. If you cannot use that, send an email to the maintainer. The address is on
   the maintainer's GitHub profile.

You get an answer within one week.

A problem that is inside the threat model above is a known limit, not a
vulnerability. Example: "a deploy role can delete its own paddock's table".
For those, open an issue or a pull request.
