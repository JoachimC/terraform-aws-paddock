# GitHub Actions presents a signed token that names the repository, the
# branch and the event. AWS trades it for a short session on a paddock's
# deploy or plan role. No access key exists, so none can leak.
#
# An account holds one provider per issuer URL. If the account already has
# this one, either import it:
#   aws iam list-open-id-connect-providers
#   terraform import 'module.account.aws_iam_openid_connect_provider.github[0]' <arn>
# or set create_github_oidc_provider = false and pass its ARN.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  # The audience aws-actions/configure-aws-credentials asks for. A token
  # minted for any other audience fails every paddock's trust policy.
  client_id_list = ["sts.amazonaws.com"]
}
