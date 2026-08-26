# ---------------------------------------------------------------------------
# The four bounded contexts, in one place.
#
# `chart_path` deliberately points OUTSIDE warehouse-infra, at the Helm chart
# that already lives in each service's own repo. warehouse-infra owns the
# ENVIRONMENT (which cluster, which database URL, which Kong route); each
# service repo owns the SHAPE of its own workload. See README.md
# "Where the manifests live" for the full rationale.
#
# `port` was read from each service's cmd/*/main.go: all four default
# HTTP_ADDR to ":8080" and the Dockerfiles all EXPOSE 8080.
# ---------------------------------------------------------------------------

locals {
  postgres_release_name = "postgres"
  postgres_host         = "${local.postgres_release_name}-postgresql.${var.data_namespace}.svc.cluster.local"
  postgres_port         = 5432

  services = {
    "inventory-storage" = {
      db         = "inventory_storage"
      user       = "inventory_storage"
      port       = 8080
      path       = "/inventory-storage"
      chart_path = "${path.module}/../../inventory-storage/charts/inventory-storage"
    }
    "wes-work-planning" = {
      db         = "wes_work_planning"
      user       = "wes_work_planning"
      port       = 8080
      path       = "/wes-work-planning"
      chart_path = "${path.module}/../../wes-work-planning/charts/wes-work-planning"
    }
    "workforce-management" = {
      db         = "workforce_management"
      user       = "workforce_management"
      port       = 8080
      path       = "/workforce-management"
      chart_path = "${path.module}/../../workforce-management/charts/workforce-management"
    }
    "fulfillment-execution" = {
      db         = "fulfillment_execution"
      user       = "fulfillment_execution"
      port       = 8080
      path       = "/fulfillment-execution"
      chart_path = "${path.module}/../../fulfillment-execution/charts/fulfillment-execution"
    }
  }

  # Per-service database passwords are GENERATED, never committed. Each service
  # gets a random 24-char password (see random_password.service_db in
  # postgres.tf); the value lives only in Terraform state, which is gitignored.
  # This keeps credentials out of version control so the repo is safe to publish.
  service_passwords = {
    for name in keys(local.services) :
    name => random_password.service_db[name].result
  }

  # sslmode=disable: the Postgres release runs without TLS inside the cluster.
  # Traffic between service pods and Postgres is not meshed either (Postgres
  # lives in an un-injected namespace), which is fine for a laptop.
  #
  # This map holds the REAL connection string each service receives (services.tf
  # feeds it into the chart's DATABASE_URL Secret), so it must carry the same
  # generated password the initdb script set on the role. It is exposed only
  # through the `database_urls` output, which is marked sensitive.
  database_urls = {
    for name, svc in local.services :
    name => "postgres://${svc.user}:${local.service_passwords[name]}@${local.postgres_host}:${local.postgres_port}/${svc.db}?sslmode=disable"
  }
}

# ---------------------------------------------------------------------------
# Observability endpoints.
#
# Names, not guesses: `otel_collector_release` is fed to the chart's
# fullnameOverride, so the Service is called exactly `otel-collector` and
# `otel_collector_endpoint` is the DNS name the five services' OTLP exporters
# are pointed at. The Jaeger v2 chart deploys ONE all-in-one Service named
# after the release (there is no separate jaeger-query Service as in the v1
# chart), which carries both OTLP 4317 and the query UI on 16686.
# ---------------------------------------------------------------------------

locals {
  otel_collector_release = "otel-collector"
  jaeger_release         = "jaeger"
  prometheus_release     = "prometheus"
  grafana_release        = "grafana"

  otel_otlp_grpc_port = 4317
  otel_otlp_http_port = 4318
  # The collector's `prometheus` exporter listens here; Prometheus scrapes it.
  otel_prometheus_exporter_port = 8889
  # The collector's own internal telemetry (queue depth, refused spans, ...).
  otel_internal_metrics_port = 8888

  jaeger_otlp_port  = 4317
  jaeger_query_port = 16686
  prometheus_port   = 9090
  grafana_port      = 3000

  observability_dns = {
    otel_collector = "${local.otel_collector_release}.${var.observability_namespace}.svc.cluster.local"
    jaeger         = "${local.jaeger_release}.${var.observability_namespace}.svc.cluster.local"
    prometheus     = "${local.prometheus_release}-server.${var.observability_namespace}.svc.cluster.local"
    grafana        = "${local.grafana_release}.${var.observability_namespace}.svc.cluster.local"
  }

  # THE endpoint. Every service's Helm values gets pointed here (in its own
  # repo — warehouse-infra does not edit service charts).
  otlp_grpc_endpoint = "${local.observability_dns.otel_collector}:${local.otel_otlp_grpc_port}"
}
