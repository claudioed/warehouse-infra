# Environment values

One file per bounded context. These hold the **static, human-editable**
environment config for the local kind cluster.

They are *overlays* on the chart defaults that already live in each service's
own repo (`<service>/charts/<service>/values.yaml`). Terraform reads the file
here and then appends a second, computed values document on top of it — image
repository/tag, `database.url`, and the Kong `ingress` route — so anything
Terraform computes wins over anything written here. See
`../terraform/services.tf`.
