#!/usr/bin/env bash
# Runs the CI checks (fmt, validate, test) with Terraform and OpenTofu in
# their official container images. CI runs this script too, so a local run
# and a CI run use the same tool versions.
#
# Usage: scripts/check.sh [--latest] [terraform|tofu]...
#   With no tool, it checks both.
#   --latest uses the newest release of each tool, not the oldest supported.
#
# Only Docker is necessary. The container works on a copy of the repo, so no
# .terraform directory or lock file appears in the working tree.
set -euo pipefail

# The oldest supported release. S3 native locking needs 1.10.
TERRAFORM_IMAGE="hashicorp/terraform:1.10"
TOFU_IMAGE="ghcr.io/opentofu/opentofu:1.10"

tag=""
tools=()
for arg in "$@"; do
  case "$arg" in
    --latest) tag="latest" ;;
    terraform | tofu) tools+=("$arg") ;;
    *)
      echo "usage: $0 [--latest] [terraform|tofu]..." >&2
      exit 2
      ;;
  esac
done
[ ${#tools[@]} -eq 0 ] && tools=(terraform tofu)

cd "$(dirname "$0")/.."

# The commands that run inside the container. $1 is the tool name.
read -r -d '' inner <<'EOF' || true
set -eu
tf="$1"
mkdir /work
tar -C /src --exclude=.terraform --exclude=.terraform.lock.hcl -cf - . | tar -C /work -xf -
cd /work
$tf version
echo "--- fmt"
$tf fmt -check -recursive -diff
# -backend=false: the example roots declare an S3 backend, and the checks
# need no AWS credentials.
for dir in modules/* examples/*; do
  echo "--- validate $dir"
  $tf -chdir="$dir" init -backend=false -input=false >/dev/null
  $tf -chdir="$dir" validate
done
# The tests use a mock provider: no AWS account is touched.
for dir in modules/*; do
  echo "--- test $dir"
  $tf -chdir="$dir" test
done
EOF

failed=()
for tool in "${tools[@]}"; do
  case "$tool" in
    terraform) image="$TERRAFORM_IMAGE" ;;
    tofu) image="$TOFU_IMAGE" ;;
  esac
  [ -n "$tag" ] && image="${image%:*}:$tag"

  echo "=== $tool ($image)"
  if ! docker run --rm \
    -v "$PWD:/src:ro" \
    -v "paddock-plugin-cache-$tool:/cache" \
    -e TF_PLUGIN_CACHE_DIR=/cache \
    -e TF_IN_AUTOMATION=1 \
    --entrypoint sh \
    "$image" -c "$inner" sh "$tool"; then
    failed+=("$tool")
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "=== failed: ${failed[*]}" >&2
  exit 1
fi
echo "=== all checks passed"
