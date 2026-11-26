# cd/orders-gateway

What each environment runs. `values.yaml` is shared by all of them; `dev.yaml`, `staging.yaml` and `prod.yaml` hold only what differs. Argo CD layers them over the chart's defaults (`helm/orders-gateway/values.yaml`): chart, then `values.yaml`, then the env file. Each environment is its own Argo CD Application in the namespace of the same name (Pod Security restricted). Promotion between environments is a Git change to `image.tag` (and `image.digest`) in the env files, and, for a chart change, to `chartVersion`.

## Chart versions

dev runs `helm/orders-gateway` as it is in Git. staging and prod run a released chart: `chartVersion: 0.2.0` in `staging.yaml` means the chart as it was at Git tag `orders-gateway-chart-0.2.0`, with today's `values.yaml` and `staging.yaml`. So a chart change reaches dev on merge and staging and prod only when their files are bumped, like an image. The Applications for staging and prod come from the ApplicationSet `orders-gateway-released` (`bootstrap/apps/templates/orders-gateway-released.yaml`), which reads these two files.

- Release a chart: bump `version` in `helm/orders-gateway/Chart.yaml` (or `./pipeline ci orders-gateway --chart 0.2.0`). The tag is made from it: by CI on GitHub after the merge, by `scripts/git-sync.sh` on the in-stack Git server. A version is released once; tags are never moved.
- Release first, then promote: a PR that bumps `Chart.yaml` and a `chartVersion` together fails validation, since the tag only exists once CI tags main. Bump `chartVersion` in a later PR (or the promotion).
- Deploy it locally: `./pipeline cd orders-gateway staging --chart 0.2.0`.
- A file that pins a version with no tag fails `scripts/validate-manifests.sh` and the push to the in-stack server (fetch the tags: `git fetch --tags`).

| | dev | staging | prod |
| --- | --- | --- | --- |
| Namespace | `dev` | `staging` | `prod` |
| Replicas | 1 | 2 | 3, HPA up to 6 on CPU |
| PDB and topology spread | no | yes | yes |
| URL | http://localhost:8082 | http://localhost:8083 | http://localhost:8080 |
| Deploy | automatic on merge to main (CI) | promotion PR the owner approves | promotion PR the owner approves |

Try it (from the host, or inside `./platform shell`):

```sh
curl -X POST http://localhost:8082/orders \
  -d '{"customer_id":"cust-1","items":[{"sku":"SKU-MUG-2","quantity":1}]}'
```
