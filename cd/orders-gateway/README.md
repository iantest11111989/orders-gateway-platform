# cd/orders-gateway

What each environment runs. `values.yaml` is shared by all of them; `dev.yaml`, `staging.yaml` and `prod.yaml` hold only what differs. Argo CD layers them over the chart's defaults (`helm/orders-gateway/values.yaml`): chart, then `values.yaml`, then the env file. Each environment is its own Argo CD Application in the namespace of the same name (Pod Security restricted). Promotion between environments is a Git change to `image.tag` (and `image.digest`) in the env files, and, for a chart change, to `chartVersion`.

## Chart versions

dev runs `helm/orders-gateway` as it is in Git. staging and prod run a released chart: `chartVersion: 0.2.0` in `staging.yaml` means `releases/orders-gateway/0.2.0/`, a copy of the chart made when 0.2.0 was released, with today's `values.yaml` and `staging.yaml`. So a chart change reaches dev on merge, and staging and prod only when their `chartVersion` is bumped, like an image. Their Applications come from the ApplicationSet `orders-gateway-released` (`bootstrap/apps/templates/orders-gateway-released.yaml`), which reads these two files. More in `releases/README.md`.

- Release a chart: `./pipeline ci orders-gateway --chart 0.2.0` sets the version in `helm/orders-gateway/Chart.yaml` and copies the chart to `releases/orders-gateway/0.2.0/`. Commit both. A version is released once; its folder is never edited.
- Deploy it locally: `./pipeline cd orders-gateway staging --chart 0.2.0`. On GitHub: a PR that changes `chartVersion`.
- A file that pins a version without a folder fails `scripts/validate-manifests.sh`.

Try it (from the host, or inside `./platform shell`):

```sh
curl -X POST http://localhost:8082/orders \
  -d '{"customer_id":"cust-1","items":[{"sku":"SKU-MUG-2","quantity":1}]}'
```
