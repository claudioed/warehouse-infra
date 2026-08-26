# ---------------------------------------------------------------------------
# Kong — north-south API gateway, fronting the mesh.
#
# Chart choice: `kong/kong` (not `kong/ingress`).
# `kong/kong` is a single release that runs Kong Gateway and Kong Ingress
# Controller as two containers in one pod, DB-less (`env.database: "off"`),
# with KIC enabled by default. `kong/ingress` is an umbrella that splits the
# controller and the gateway into two subchart releases wired together by
# gatewayDiscovery — more moving parts, more to go wrong on a laptop, and no
# benefit at this scale. Routing is therefore plain Kubernetes `Ingress`
# objects with ingressClassName: kong, which is what KIC watches out of the
# box and what the services' existing Helm charts already know how to emit.
# No Gateway API CRDs are required.
#
# Exposure: proxy Service is NodePort (there is no cloud load balancer here);
# kind's extraPortMappings publish those NodePorts on the host. See main.tf.
# ---------------------------------------------------------------------------

resource "helm_release" "kong" {
  depends_on = [
    kubernetes_namespace.kong,
    helm_release.istiod,
  ]

  name       = "kong"
  repository = "https://charts.konghq.com"
  chart      = "kong"
  version    = var.kong_chart_version
  namespace  = var.kong_namespace

  timeout = 900
  wait    = true

  values = [yamlencode({
    env = {
      database = "off"
    }

    proxy = {
      enabled = true
      type    = "NodePort"
      http = {
        enabled       = true
        servicePort   = 80
        containerPort = 8000
        nodePort      = var.kong_proxy_http_node_port
      }
      tls = {
        enabled       = true
        servicePort   = 443
        containerPort = 8443
        nodePort      = var.kong_proxy_https_node_port
      }
    }

    ingressController = {
      enabled      = true
      ingressClass = "kong"
    }

    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { cpu = "1000m", memory = "1Gi" }
    }
  })]
}
