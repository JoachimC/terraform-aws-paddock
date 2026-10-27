#!/usr/bin/env bash
# Apply the account root: the account layer and every paddock.
#
# Terraform needs somewhere to keep state before it can create anything, and
# the bucket that holds state cannot hold the state of the run that creates
# it. So the first run keeps state on this machine, creates the bucket, then
# moves its own state into the bucket and deletes the local file. Every later
# run reads state from the bucket.
#
# The region comes from your AWS configuration on the first run only. After
# that it comes from the state bucket itself, so an admin with a different
# default region cannot split the account across two regions.
#
# Usage: paddock-init.sh [-C root-dir] [tfvars-file]
#   root-dir     the account root (default: current directory)
#   tfvars-file  relative to root-dir (default: account.tfvars)
#
# Environment:
#   PADDOCK_TF   terraform or tofu (default: terraform if installed, else tofu)
#   AWS_PROFILE  the profile to use; export it so every command in the run
#                uses the same credentials
set -euo pipefail

ROOT="."
if [ "${1:-}" = "-C" ]; then
  ROOT="${2:?-C needs a directory}"
  shift 2
fi
TFVARS="${1:-account.tfvars}"

cd "$ROOT"
if [ ! -f "$TFVARS" ]; then
  echo "error: $ROOT/$TFVARS not found. Copy example.tfvars to it and fill it in." >&2
  exit 1
fi

if [ -n "${PADDOCK_TF:-}" ]; then
  TF="$PADDOCK_TF"
elif command -v terraform > /dev/null; then
  TF=terraform
elif command -v tofu > /dev/null; then
  TF=tofu
else
  echo "error: neither terraform nor tofu is on the PATH." >&2
  exit 1
fi
echo "==> Using $TF ($("$TF" version | head -n 1))"

# Reads `name = "value"` from a tfvars file. Good enough for the one plain
# string this script needs; Terraform itself reads the rest.
value_of() { # value_of <tfvars-file> <variable-name>
  awk -F'"' -v name="$2" '$0 ~ "^[[:space:]]*" name "[[:space:]]*=" {print $2; exit}' "$1"
}

PREFIX="$(value_of "$TFVARS" state_bucket_prefix)"
if [ -z "$PREFIX" ]; then
  echo "error: state_bucket_prefix is not set in $TFVARS." >&2
  exit 1
fi

if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2> /dev/null)"; then
  echo "error: no AWS credentials." >&2
  echo "Sign in, then export the profile so every command in this run uses it:" >&2
  echo "  aws login --profile <profile>" >&2
  echo "  export AWS_PROFILE=<profile>" >&2
  exit 1
fi

BUCKET="${PREFIX}-terraform-state-${ACCOUNT}"
KEY="account/terraform.tfstate"
LOCAL_STATE="$HOME/.paddock/${ACCOUNT}/account.tfstate"
OVERRIDE="paddock_backend_override.tf"

# --expected-bucket-owner turns "someone else owns this name" into an error
# instead of a bucket we would try to write to.
if aws s3api head-bucket --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT" > /dev/null 2>&1; then
  BUCKET_EXISTS=true
  REGION="$(aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text)"
  # S3 reports us-east-1 as an empty location.
  if [ -z "$REGION" ] || [ "$REGION" = "None" ] || [ "$REGION" = "null" ]; then
    REGION=us-east-1
  fi
  echo "==> State bucket s3://${BUCKET} is in ${REGION}"
else
  BUCKET_EXISTS=false
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2> /dev/null || true)}}"
  if [ -z "$REGION" ]; then
    echo "error: no default region. Set AWS_REGION, or a region in your AWS profile." >&2
    exit 1
  fi
  echo "==> First run: the account layer goes to ${REGION}, your default region"
fi

STATE_IN_BUCKET=false
if [ "$BUCKET_EXISTS" = true ] && aws s3api head-object --bucket "$BUCKET" --key "$KEY" --region "$REGION" > /dev/null 2>&1; then
  STATE_IN_BUCKET=true
fi

BACKEND=(
  -backend-config="bucket=${BUCKET}"
  -backend-config="key=${KEY}"
  -backend-config="region=${REGION}"
  -backend-config="use_lockfile=true"
  -backend-config="encrypt=true"
)
VARS=(-var-file="$TFVARS" -var "aws_region=${REGION}")

# An _override.tf file wins the merge with the root's backend block, so this
# swaps the S3 backend for a local one until migrate_local_state_to_bucket
# deletes it.
use_local_state() {
  mkdir -p "$(dirname "$LOCAL_STATE")"
  chmod 700 "$(dirname "$LOCAL_STATE")"
  cat > "$OVERRIDE" << 'HCL'
# Written by paddock-init.sh for the first run, and deleted by it. Never
# commit this file; .gitignore names it.
terraform {
  backend "local" {}
}
HCL
  "$TF" init -input=false -reconfigure -backend-config="path=${LOCAL_STATE}"
}

migrate_local_state_to_bucket() {
  echo
  echo "==> Phase 2 of 2: move the state into s3://${BUCKET}/${KEY}"
  rm -f "$OVERRIDE"
  "$TF" init -input=false -migrate-state -force-copy "${BACKEND[@]}"
  rm -f "$LOCAL_STATE" "${LOCAL_STATE}.backup"
  echo "Removed ${LOCAL_STATE}. The bucket now holds the only copy."
}

if [ "$STATE_IN_BUCKET" = true ]; then
  echo "==> State is in s3://${BUCKET}/${KEY}"
  rm -f "$OVERRIDE"
  "$TF" init -input=false -reconfigure "${BACKEND[@]}"
  "$TF" apply "${VARS[@]}"
elif [ "$BUCKET_EXISTS" = true ] && [ -f "$LOCAL_STATE" ]; then
  # Phase 1 finished, phase 2 did not. Usually admin_principal_arns did not
  # match the caller, and the new bucket policy refused the write. Apply
  # again with local state so a corrected list reaches the policy, then move.
  echo "==> The bucket exists and the state is still on this machine: finishing an earlier first run"
  use_local_state
  "$TF" apply "${VARS[@]}"
  migrate_local_state_to_bucket
elif [ "$BUCKET_EXISTS" = true ]; then
  echo "error: s3://${BUCKET} exists but holds no ${KEY}, and ${LOCAL_STATE} does not exist." >&2
  echo "The state of an earlier first run is lost. Import the existing resources into a new" >&2
  echo "state (see Recovery in the README), or delete them and run this script again." >&2
  exit 1
else
  echo "==> Phase 1 of 2: apply with state on this machine, because the bucket does not exist yet"
  use_local_state
  "$TF" apply "${VARS[@]}"
  migrate_local_state_to_bucket
fi

echo
echo "==> Repository variables for each paddock"
"$TF" output -raw github_variable_commands 2> /dev/null || echo "(the root has no github_variable_commands output)"
echo
