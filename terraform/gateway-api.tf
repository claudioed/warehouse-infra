# ---------------------------------------------------------------------------
# Gateway API — pilot phase.
#
# Kong currently fronts every service via plain Kubernetes `Ingress` objects
# (see kong.tf's header comment on that original choice). This introduces
# the Kubernetes Gateway API as an ADDITIVE, parallel routing mechanism:
# Kong's own Ingress Controller (KIC) ships both an Ingress reconciler and a
# Gateway API reconciler ENABLED BY DEFAULT in the same process (verified
# against the real `kong/kubernetes-ingress-controller:3.5` image — both
# `--enable-controller-ingress-class-networkingv1` and
# `--enable-controller-gwapi-httproute` default to true), so a service can
# move from Ingress to HTTPRoute without a fleet-wide flag day and without
# any other service's routing changing underneath it.
#
# PILOT SCOPE: this phase stands up the Gateway API platform pieces (CRDs,
# GatewayClass, Gateway) and migrates exactly ONE service
# (fulfillment-execution, the fleet's existing reference implementation) to
# HTTPRoute, as a real end-to-end validation before touching the other six.
# The remaining six services keep their existing Ingress objects untouched
# — see services.tf's `ingress` block, which still applies to them.
#
# Why not the `kubernetes_manifest` provider resource for the CRDs
# themselves: it needs the CRD's OpenAPI schema to validate the resource at
# PLAN time, which does not exist yet on a `terraform apply` that installs
# the CRD and a custom resource using it in the same run — a real, known
# chicken/egg limitation of that provider. A `null_resource` + `kubectl
# apply` avoids it and matches this module's own existing pattern for
# cluster-side actions Terraform's typed providers don't cleanly cover
# (see main.tf's kubeconfig export).
# ---------------------------------------------------------------------------

resource "null_resource" "gateway_api_crds" {
  count = var.deploy_gateway_api ? 1 : 0

  depends_on = [null_resource.kubeconfig]

  triggers = {
    version = var.gateway_api_version
    # Re-run if the cluster gets recreated, since the CRDs live IN the
    # cluster and do not survive a kind_cluster replacement.
    cluster_id  = kind_cluster.warehouse.id
    kubeconfig  = local.kubeconfig_path
    api_version = var.gateway_api_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig '${local.kubeconfig_path}' apply -f \
        https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml
    EOT
  }

  # local-exec has no built-in destroy counterpart, so a plain count=0 (or
  # `terraform destroy`) would otherwise leave these CRDs -- and therefore
  # every GatewayClass/Gateway/HTTPRoute instance depending on them --
  # ORPHANED in the cluster with no Terraform state tracking them at all.
  # Verified this the hard way: after flipping deploy_gateway_api to false,
  # `terraform apply` reported the resources destroyed while `kubectl get
  # gateway,httproute,gatewayclass` still showed all three, 20+ minutes
  # old, completely untracked. `when = destroy` + `self.triggers` (the only
  # values available to a destroy-time provisioner) fixes it for the
  # ordinary count-1-to-0 case; a bare `terraform destroy` still relies on
  # down.sh's kind-cluster-deletion safety net, which removes everything
  # at once regardless of provisioner ordering.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${self.triggers.api_version}/standard-install.yaml --ignore-not-found=true || true"
  }
}

# The GatewayClass: a cluster-scoped "which controller implements this"
# declaration. controllerName is Kong KIC's own default
# (`konghq.com/kic-gateway-controller`, matched exactly against the real
# binary's --gateway-api-controller-name flag default, not guessed).
resource "null_resource" "gateway_class" {
  count = var.deploy_gateway_api ? 1 : 0

  depends_on = [
    null_resource.gateway_api_crds,
    helm_release.kong,
  ]

  triggers = {
    cluster_id = kind_cluster.warehouse.id
    kubeconfig = local.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'MANIFEST' | kubectl --kubeconfig '${local.kubeconfig_path}' apply -f -
      apiVersion: gateway.networking.k8s.io/v1
      kind: GatewayClass
      metadata:
        name: kong
      spec:
        controllerName: konghq.com/kic-gateway-controller
      MANIFEST
    EOT
  }

  # See gateway_api_crds' destroy provisioner comment: local-exec resources
  # need an explicit destroy-time counterpart or count=0 orphans the object.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete gatewayclass kong --ignore-not-found=true || true"
  }
}

# The Gateway: the actual listener KIC programs into the running Kong
# proxy. One shared Gateway for the whole fleet, matching the existing
# "one Kong release fronts every service" topology — HTTPRoutes attach to
# this by name via parentRefs, they do not each get their own Gateway.
resource "null_resource" "gateway" {
  count = var.deploy_gateway_api ? 1 : 0

  depends_on = [null_resource.gateway_class]

  triggers = {
    cluster_id = kind_cluster.warehouse.id
    kubeconfig = local.kubeconfig_path
    name       = local.gateway_name
    namespace  = var.kong_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'MANIFEST' | kubectl --kubeconfig '${local.kubeconfig_path}' apply -f -
      apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      metadata:
        name: ${local.gateway_name}
        namespace: ${var.kong_namespace}
      spec:
        gatewayClassName: kong
        listeners:
          - name: http
            protocol: HTTP
            port: 80
            allowedRoutes:
              namespaces:
                from: All
      MANIFEST
    EOT
  }

  # See gateway_api_crds' destroy provisioner comment.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete gateway '${self.triggers.name}' -n '${self.triggers.namespace}' --ignore-not-found=true || true"
  }
}

locals {
  gateway_name = "warehouse-gateway"
}

# ---------------------------------------------------------------------------
# The pilot HTTPRoute: fulfillment-execution only (see services.tf's
# local.gateway_api_pilot_services). Mirrors exactly what its Ingress
# object would have expressed -- same path prefix, same strip-prefix
# behavior -- via HTTPRoute's own `filters` block, so this is a like-for-
# like routing swap, not a behavior change. Kong's KIC reconciles this the
# same way it reconciles the other six services' Ingress objects: attach
# via `parentRefs` to the shared Gateway (not a per-service Gateway), Kong
# programs the matching route into the running proxy.
#
# Applied directly here (not via the service's own Helm chart) because
# none of the seven charts ship an httproute.yaml template yet -- see the
# comment on gateway_api_pilot_services for why that fan-out is deferred
# until this pilot proves the pattern end to end.
# ---------------------------------------------------------------------------

resource "null_resource" "fulfillment_execution_httproute" {
  count = var.deploy_gateway_api && var.deploy_services && contains(local.gateway_api_pilot_services, "fulfillment-execution") ? 1 : 0

  depends_on = [
    null_resource.gateway,
    helm_release.service,
  ]

  triggers = {
    cluster_id = kind_cluster.warehouse.id
    kubeconfig = local.kubeconfig_path
    namespace  = var.apps_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'MANIFEST' | kubectl --kubeconfig '${local.kubeconfig_path}' apply -f -
      apiVersion: gateway.networking.k8s.io/v1
      kind: HTTPRoute
      metadata:
        name: fulfillment-execution
        namespace: ${var.apps_namespace}
      spec:
        parentRefs:
          - name: ${local.gateway_name}
            namespace: ${var.kong_namespace}
            sectionName: http
        rules:
          - matches:
              - path:
                  type: PathPrefix
                  value: ${local.services["fulfillment-execution"].path}
            filters:
              - type: URLRewrite
                urlRewrite:
                  path:
                    type: ReplacePrefixMatch
                    replacePrefixMatch: /
            backendRefs:
              - name: fulfillment-execution
                port: 80
      MANIFEST
    EOT
  }

  # See gateway_api_crds' destroy provisioner comment.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --kubeconfig '${self.triggers.kubeconfig}' delete httproute fulfillment-execution -n '${self.triggers.namespace}' --ignore-not-found=true || true"
  }
}

output "gateway_api_installed" {
  description = "Whether the Gateway API CRDs/GatewayClass/Gateway are installed."
  value       = var.deploy_gateway_api
}
