# environments

One `values.yaml` per environment. Each overrides `charts/orders-gateway/values.yaml` and is deployed by its own Argo CD Application to the namespace of the same name (Pod Security restricted). Promotion between environments is a Git change to `image.tag` (and `image.digest`) in these files.

| | dev | staging | prod |
| --- | --- | --- | --- |
| Namespace | `dev` | `staging` | `prod` |
| Replicas | 1 | 2 | 3, HPA up to 6 on CPU |
| PDB and topology spread | no | yes | yes |
| URL | https://orders.dev.localtest.me | https://orders.staging.localtest.me | https://orders.localtest.me |
| Deploy | automatic on merge to main (CI) | promotion PR the owner approves | promotion PR the owner approves; canary |

Try it (inside `./platform shell`, or from the host with the demo CA):

```sh
curl --cacert .build/ogp-demo-ca.crt -X POST https://orders.dev.localtest.me/orders \
  -d '{"customer_id":"cust-1","items":[{"sku":"SKU-MUG-2","quantity":1}]}'
```
