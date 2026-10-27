terraform {
  # 1.10 is the first Terraform and the first OpenTofu with native S3 state
  # locking, so no DynamoDB lock table is needed.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.0 renamed the region attribute of the aws_region data source to
      # `region`, which this module reads.
      version = ">= 6.0"
    }
  }
}
