#!/usr/bin/env bash
# Single entrypoint: bring the whole local environment up from nothing.
#
#     ./scripts/up.sh
#
# terraform apply does all of it — creates the kind cluster, installs
# PostgreSQL / Istio / Kong, then builds the four service images, loads them
# into kind and installs the four service charts. Re-running is idempotent;
# images rebuild only when their source changes.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${INFRA_DIR}/terraform"

for tool in docker kind helm terraform kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is not on PATH" >&2; exit 1; }
done

if ! docker info >/dev/null 2>&1; then
  echo "error: the Docker daemon is not reachable — start Docker Desktop first" >&2
  exit 1
fi

echo "==> terraform init"
terraform init -input=false

echo "==> terraform apply"
terraform apply -input=false -auto-approve "$@"

echo
echo "==> done. cluster is up."
terraform output routes
echo
echo "Try it:"
echo "  curl -i $(terraform output -raw kong_proxy_url)/inventory-storage/healthz"

# The observability UIs are ClusterIP only — Kong routes the four services,
# not the telemetry stack — so they are reached with a port-forward.
if [[ -n "$(terraform output -raw observability_namespace 2>/dev/null)" ]]; then
  echo
  echo "==> observability. Services send OTLP/gRPC to:"
  echo "  $(terraform output -raw otlp_endpoint)"
  echo
  echo "UIs (each needs its own port-forward; Grafana logs in as admin / admin):"
  terraform output -json observability_port_forwards \
    | python3 -c 'import json,sys; [print("  " + v) for v in json.load(sys.stdin).values()]'
fi
