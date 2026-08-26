#!/usr/bin/env bash
# Tear everything down. `terraform destroy` removes the Helm releases and then
# deletes the kind cluster, which is what actually reclaims the Docker
# containers and their disk.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${INFRA_DIR}/terraform"

CLUSTER="$(terraform output -raw cluster_name 2>/dev/null || echo warehouse)"

echo "==> terraform destroy"
terraform destroy -input=false -auto-approve "$@" || {
  echo "warning: terraform destroy did not complete cleanly; forcing cluster deletion" >&2
}

# Safety net: if the destroy failed part-way (e.g. a Helm release that could not
# be reached because the API server was already gone), the cluster can survive.
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "==> kind delete cluster --name ${CLUSTER}"
  kind delete cluster --name "${CLUSTER}"
fi

rm -f kubeconfig
echo "==> torn down"
