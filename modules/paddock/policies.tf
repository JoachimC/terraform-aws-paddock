locals {
  # --- Statements shared by the deploy role and the plan role -------------

  state_list_statement = {
    Sid      = "StateList"
    Effect   = "Allow"
    Action   = "s3:ListBucket"
    Resource = local.state_bucket_arn
    Condition = {
      StringLike = { "s3:prefix" = ["${local.state_prefix}/*"] }
    }
  }

  # The S3 backend writes a lock object beside the state and deletes it at
  # the end of the run. Delete reaches the lock object only, so no run can
  # remove its own state.
  state_lock_statement = {
    Sid      = "StateLock"
    Effect   = "Allow"
    Action   = ["s3:PutObject", "s3:DeleteObject"]
    Resource = "${local.state_bucket_arn}/${local.state_prefix}/*.tflock"
  }

  identity_statement = {
    Sid      = "Identity"
    Effect   = "Allow"
    Action   = "sts:GetCallerIdentity"
    Resource = "*"
  }

  public_parameters_statement = {
    Sid      = "ReadPublicParameters"
    Effect   = "Allow"
    Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    Resource = local.public_parameter_arns
  }

  global_read_actions = distinct(flatten([for scope in local.chosen_named_services : scope.global]))

  global_read_statements = length(local.global_read_actions) == 0 ? [] : [{
    Sid      = "ListAndDescribe"
    Effect   = "Allow"
    Action   = local.global_read_actions
    Resource = "*"
  }]

  dns_read_statements = [for s in [
    {
      Sid      = "DnsZoneRead"
      Effect   = "Allow"
      Action   = ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
      Resource = local.hosted_zone_arn
    },
    {
      Sid      = "DnsChangeStatus"
      Effect   = "Allow"
      Action   = "route53:GetChange"
      Resource = "${local.arn}:route53:::change/*"
    },
    {
      Sid      = "DnsList"
      Effect   = "Allow"
      Action   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
      Resource = "*"
    },
    {
      Sid      = "WildcardCertificateRead"
      Effect   = "Allow"
      Action   = ["acm:DescribeCertificate", "acm:ListTagsForCertificate"]
      Resource = coalesce(var.account.wildcard_certificate_arn, "${local.arn}:acm:${local.region}:${local.account}:certificate/none")
    },
  ] : s if local.publishes_dns]

  # --- Deploy role ----------------------------------------------------------

  deploy_named_statements = [for service, scope in local.chosen_named_services : {
    Sid      = "Manage${replace(title(service), "/[^A-Za-z0-9]/", "")}"
    Effect   = "Allow"
    Action   = "${service}:*"
    Resource = scope.named
  }]

  # Event source mappings get a generated id. Lambda scopes them by the
  # function they feed instead.
  deploy_lambda_statements = contains(var.aws_services, "lambda") ? [{
    Sid    = "ManageEventSourceMappings"
    Effect = "Allow"
    Action = [
      "lambda:CreateEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping",
    ]
    Resource = "*"
    Condition = {
      ArnLike = { "lambda:FunctionArn" = "${local.arn}:lambda:${local.region}:${local.account}:function:${local.n}-*" }
    }
  }] : []

  deploy_apigateway_statements = concat(
    [for s in [
      {
        Sid       = "CreateRestApi"
        Effect    = "Allow"
        Action    = "apigateway:POST"
        Resource  = "${local.apigateway_arn}/restapis"
        Condition = local.request_tag
      },
      # Tags sent with a create may be checked as a separate tagging call, on
      # a resource that has no tags yet.
      {
        Sid       = "TagOnCreate"
        Effect    = "Allow"
        Action    = "apigateway:PUT"
        Resource  = "${local.apigateway_arn}/tags/*"
        Condition = local.request_tag
      },
      {
        Sid       = "ManageOwnRestApis"
        Effect    = "Allow"
        Action    = "apigateway:*"
        Resource  = ["${local.apigateway_arn}/restapis/*", "${local.apigateway_arn}/tags/*"]
        Condition = local.own_tag
      },
      {
        Sid      = "ListRestApisAndDomains"
        Effect   = "Allow"
        Action   = "apigateway:GET"
        Resource = ["${local.apigateway_arn}/restapis", "${local.apigateway_arn}/domainnames"]
      },
    ] : s if local.apigateway],
    [for s in [
      {
        Sid       = "CreateDomainName"
        Effect    = "Allow"
        Action    = "apigateway:POST"
        Resource  = "${local.apigateway_arn}/domainnames"
        Condition = local.request_tag
      },
      {
        Sid      = "ManageOwnDomainNames"
        Effect   = "Allow"
        Action   = "apigateway:*"
        Resource = local.domain_name_arns
      },
    ] : s if local.apigateway && local.publishes_dns],
  )

  deploy_kms_statements = [for s in [
    {
      Sid       = "CreateKey"
      Effect    = "Allow"
      Action    = ["kms:CreateKey", "kms:TagResource"]
      Resource  = "*"
      Condition = local.request_tag
    },
    {
      Sid       = "ManageOwnKeys"
      Effect    = "Allow"
      Action    = "kms:*"
      Resource  = local.kms_key_arns
      Condition = local.own_tag
    },
    {
      Sid      = "ManageOwnAliases"
      Effect   = "Allow"
      Action   = ["kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"]
      Resource = local.kms_alias_arns
    },
    {
      Sid      = "ListKeys"
      Effect   = "Allow"
      Action   = ["kms:ListAliases", "kms:ListKeys"]
      Resource = "*"
    },
  ] : s if local.kms]

  deploy_state_statements = [
    local.state_list_statement,
    {
      Sid      = "StateReadWrite"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "${local.state_bucket_arn}/${local.state_prefix}/*"
    },
    local.state_lock_statement,
  ]

  # The deploy role may change what its runtime roles may do, inside the
  # boundary, and hand them to Lambda. It may never create a role, change a
  # role's trust, or touch a boundary: those are the steps that would let a
  # paddock reach outside itself.
  deploy_iam_statements = [
    {
      Sid    = "RuntimeRolePolicies"
      Effect = "Allow"
      Action = [
        "iam:GetRole",
        "iam:ListRoleTags",
        "iam:ListRolePolicies",
        "iam:GetRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListAttachedRolePolicies",
      ]
      Resource = local.runtime_role_arns
    },
    {
      Sid      = "PassRuntimeRoles"
      Effect   = "Allow"
      Action   = "iam:PassRole"
      Resource = local.runtime_role_arns
      Condition = {
        StringEquals = { "iam:PassedToService" = var.runtime_service }
      }
    },
    {
      Sid    = "DenyRoleCreationTrustAndBoundaryChanges"
      Effect = "Deny"
      Action = [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePermissionsBoundary",
        "iam:DeleteRolePermissionsBoundary",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:CreatePolicy",
        "iam:CreatePolicyVersion",
        "iam:SetDefaultPolicyVersion",
      ]
      Resource = "*"
    },
  ]

  # Only these names, only these record types. A paddock cannot touch
  # another paddock's hostname or the zone's own NS and SOA records.
  deploy_dns_statements = local.publishes_dns ? [{
    Sid      = "DnsOwnRecords"
    Effect   = "Allow"
    Action   = "route53:ChangeResourceRecordSets"
    Resource = local.hosted_zone_arn
    Condition = {
      "ForAllValues:StringEquals" = {
        "route53:ChangeResourceRecordSetsNormalizedRecordNames" = var.hostnames
        "route53:ChangeResourceRecordSetsRecordTypes"           = ["A", "AAAA", "CNAME", "TXT"]
      }
    }
  }] : []

  deploy_tag_guard_statements = [
    {
      Sid      = "DenyTaggingForAnotherPaddock"
      Effect   = "Deny"
      Action   = "*"
      Resource = "*"
      Condition = {
        StringNotEquals = { "aws:RequestTag/Paddock" = local.n }
        Null            = { "aws:RequestTag/Paddock" = "false" }
      }
    },
  ]

  deploy_untag_guard_statements = length(local.untag_actions) == 0 ? [] : [{
    Sid      = "DenyRemovingPaddockTag"
    Effect   = "Deny"
    Action   = local.untag_actions
    Resource = "*"
    Condition = {
      "ForAnyValue:StringEquals" = { "aws:TagKeys" = ["Paddock"] }
    }
  }]

  deploy_policy = {
    Version = "2012-10-17"
    Statement = concat(
      local.deploy_state_statements,
      [local.identity_statement, local.public_parameters_statement],
      local.global_read_statements,
      local.deploy_named_statements,
      local.deploy_lambda_statements,
      local.deploy_apigateway_statements,
      local.deploy_kms_statements,
      local.deploy_iam_statements,
      local.dns_read_statements,
      local.deploy_dns_statements,
      local.deploy_tag_guard_statements,
      local.deploy_untag_guard_statements,
    )
  }

  # --- Plan role ------------------------------------------------------------

  plan_named_statements = [for service, scope in local.chosen_named_services : {
    Sid      = "Read${replace(title(service), "/[^A-Za-z0-9]/", "")}"
    Effect   = "Allow"
    Action   = scope.read
    Resource = scope.named
  }]

  plan_apigateway_statements = [for s in [
    {
      Sid       = "ReadOwnRestApis"
      Effect    = "Allow"
      Action    = "apigateway:GET"
      Resource  = ["${local.apigateway_arn}/restapis/*", "${local.apigateway_arn}/tags/*"]
      Condition = local.own_tag
    },
    {
      Sid      = "ReadRestApiAndDomainLists"
      Effect   = "Allow"
      Action   = "apigateway:GET"
      Resource = concat(["${local.apigateway_arn}/restapis", "${local.apigateway_arn}/domainnames"], local.domain_name_arns)
    },
  ] : s if local.apigateway]

  plan_kms_statements = [for s in [
    {
      Sid       = "ReadOwnKeys"
      Effect    = "Allow"
      Action    = ["kms:Describe*", "kms:Get*", "kms:List*"]
      Resource  = local.kms_key_arns
      Condition = local.own_tag
    },
    {
      Sid      = "ListKeys"
      Effect   = "Allow"
      Action   = ["kms:ListAliases", "kms:ListKeys"]
      Resource = "*"
    },
  ] : s if local.kms]

  plan_policy = {
    Version = "2012-10-17"
    Statement = concat(
      [
        local.state_list_statement,
        {
          Sid      = "StateRead"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${local.state_bucket_arn}/${local.state_prefix}/*"
        },
        local.state_lock_statement,
        local.identity_statement,
        local.public_parameters_statement,
        {
          Sid      = "ReadRuntimeRoles"
          Effect   = "Allow"
          Action   = ["iam:GetRole", "iam:ListRoleTags", "iam:ListRolePolicies", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies"]
          Resource = local.runtime_role_arns
        },
      ],
      local.global_read_statements,
      local.plan_named_statements,
      local.plan_apigateway_statements,
      local.plan_kms_statements,
      local.dns_read_statements,
    )
  }

  # --- Runtime boundary -------------------------------------------------------

  # The most a runtime role can ever do. The deploy role writes the runtime
  # role's inline policy; the effective rights are that policy and this
  # boundary together, so a typo such as "Action": "*" stays in the paddock.
  boundary_named_statements = [for service, scope in local.chosen_named_services : {
    Sid      = "Use${replace(title(service), "/[^A-Za-z0-9]/", "")}"
    Effect   = "Allow"
    Action   = "${service}:*"
    Resource = scope.named
  } if service != "ecr"]

  boundary_policy = {
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "FunctionLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = local.function_log_groups
        },
        {
          Sid      = "Tracing"
          Effect   = "Allow"
          Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
          Resource = "*"
        },
        {
          Sid      = "OwnParameters"
          Effect   = "Allow"
          Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
          Resource = concat(["${local.arn}:ssm:${local.region}:${local.account}:parameter/${local.n}/*"], local.public_parameter_arns)
        },
      ],
      length(var.reads_from) == 0 ? [] : [{
        Sid      = "SharedSecretsFromOtherPaddocks"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [for owner in var.reads_from : "${local.arn}:secretsmanager:${local.region}:${local.account}:secret:${owner}/shared/*"]
      }],
      local.boundary_named_statements,
      local.kms ? [{
        Sid    = "UseOwnKeys"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*",
          "kms:DescribeKey",
          "kms:GetPublicKey",
          "kms:Sign",
          "kms:Verify",
          "kms:GenerateMac",
          "kms:VerifyMac",
        ]
        Resource  = local.kms_key_arns
        Condition = local.own_tag
      }] : [],
    )
  }

  # Writes the function's logs, so a new function works on its first deploy
  # before the service adds its own policy.
  runtime_baseline_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid      = "FunctionLogs"
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = local.function_log_groups
    }]
  }
}
