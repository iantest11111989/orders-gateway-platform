# environments

One `values.yaml` per environment. Each overrides `charts/orders-gateway/values.yaml` and is deployed by its own Argo CD Application to namespace `orders-<env>` (Pod Security restricted). Promotion between environments is a Git change to `image.tag` (and `image.digest`) in these files. See [decision 0009](../docs/decisions/0009-chart-and-environments.md).

| | dev | staging | prod |
| --- | --- | --- | --- |
| Namespace | `orders-dev` | `orders-staging` | `orders-prod` |
| Replicas | 1 | 2 | 3, HPA up to 6 on CPU |
| PDB and topology spread | no | yes | yes |
| URL | https://orders.dev.localtest.me | https://orders.staging.localtest.me | https://orders.localtest.me |
| Deploy | automatic on merge to main (coming) | promotion PR the owner approves | promotion PR the owner approves; canary (coming) |

Try it (inside `./platform shell`, or from the host with the demo CA):

```sh
curl --cacert .build/ogp-demo-ca.crt -X POST https://orders.dev.localtest.me/orders \
  -d '{"customer_id":"cust-1","items":[{"sku":"SKU-MUG-2","quantity":1}]}'
```
