# Contributing

Thank you for your interest. One person maintains this project. The process
is small, but these rules keep the history easy to read.

## Before you start

1. Open an issue first. Do this for every change that is larger than a typo.
2. Describe the behaviour that you see. For an IAM problem, include the
   `AccessDenied` message: it names the action and the resource.
3. Read the open issues. Some known tasks are already there.

## Workflow

1. Make one branch for one issue. Start the branch from the current `main`.
2. Name the branch `issue-N-short-description`.
3. Open one pull request for the branch. Put `Closes #N` in the pull request
   body. The issue then closes when the pull request merges.
4. Keep the pull request small. Put format-only changes and rename-only
   changes in their own pull requests.
5. In the pull request body, say if you applied the change to a real AWS
   account. The tests use a mock provider: they check the policies the
   modules write, not what AWS does with them. You can submit a change that
   you only tested with the mock. But say so.

## Code

* The modules support Terraform 1.10 or later and OpenTofu 1.10 or later. Use
  only what both tools support. CI runs every check with both.
* Before you push, run these commands. CI runs the same commands.
  ```bash
  terraform fmt -check -recursive
  for dir in modules/* examples/*; do terraform -chdir="$dir" init -backend=false && terraform -chdir="$dir" validate; done
  for dir in modules/*; do terraform -chdir="$dir" test; done
  shellcheck scripts/*.sh
  ```
  The same commands with `tofu` in place of `terraform` must also pass.
* Build IAM policies with `jsonencode`, not the `aws_iam_policy_document`
  data source. The tests can then read a policy at plan time without AWS.
* Scope every new permission by the paddock's name or its `Paddock` tag.
  Never widen an Allow to `*` resources for an action that takes a resource.
* Write comments that say *why*, not *what*. The existing code records the
  limit or the failure that caused a decision. Do the same when you add a
  decision that is not obvious.

## Tests

* Each module has its tests in `tests/`, run by `terraform test` and
  `tofu test` with a mock provider.
* Name each run `given_<state>_when_<action>_then_<outcome>`. The name must
  state the defect that the test prevents. Example:
  `given_any_services_when_applied_then_deploy_role_cannot_create_roles_or_change_boundaries`.
* A change to a policy comes with a test that reads the policy and checks the
  change.

## Support and the Maintenance Fee

The project participates in the
[Open Source Maintenance Fee](https://opensourcemaintenancefee.org). See
`OSMFEULA.txt` and the README. Questions and issues from commercial users who
pay the fee get priority. All other questions and issues are welcome. The
maintainer answers them when time permits.

## Licensing

When you submit a contribution, you agree that it is licensed under
MIT OR Apache-2.0. This is the same licence as the project. See the License
section in `README.md`.
