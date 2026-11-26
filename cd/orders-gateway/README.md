# cd/orders-gateway

What each environment runs. `values.yaml` is shared by all of them; `dev.yaml`, `staging.yaml` and `prod.yaml` hold only what differs. Argo CD layers them over the chart's defaults (`helm/orders-gateway/values.yaml`): chart, then `values.yaml`, then the env file. Each environment is its own Argo CD Application in the namespace of the same name (Pod Security restricted). Promotion between environments is a Git change to `image.tag` (and `image.digest`) in the env files.

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
