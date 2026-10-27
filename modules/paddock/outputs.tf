locals {
  github_variables = merge(
    {
      PADDOCK             = local.n
      AWS_REGION          = local.region
      TF_STATE_BUCKET     = var.account.state_bucket
      TF_STATE_KEY        = local.state_key
      AWS_DEPLOY_ROLE_ARN = aws_iam_role.deploy.arn
    },
    var.plan_role ? { AWS_PLAN_ROLE_ARN = aws_iam_role.plan[0].arn } : {},
  )
}

output "name" {
  description = "Paddock name. Also its Paddock tag value and its state key prefix."
  value       = local.n
}

output "deploy_role_arn" {
  description = "Role that the deploy workflow assumes."
  value       = aws_iam_role.deploy.arn
}

output "plan_role_arn" {
  description = "Read-only role that pull request workflows assume, or null."
  value       = var.plan_role ? aws_iam_role.plan[0].arn : null
}

output "runtime_role_arns" {
  description = "Runtime role ARNs by role name."
  value       = { for role, resource in aws_iam_role.runtime : role => resource.arn }
}

output "boundary_arn" {
  description = "Permissions boundary on every runtime role."
  value       = aws_iam_policy.boundary.arn
}

output "state_key" {
  description = "State key for the paddock's own Terraform."
  value       = local.state_key
}

output "github_variables" {
  description = "Repository variables for the paddock's repository. None of them is secret."
  value       = local.github_variables
}

output "github_variable_commands" {
  description = "gh commands that set github_variables on the paddock's repository."
  value = join("\n", [
    for key, value in local.github_variables : "gh variable set ${key} --body '${value}' --repo ${var.github_repository}"
  ])
}
