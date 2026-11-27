# apps/orders-gateway/cd

What each environment runs. `values.yaml` is shared. `dev.yaml`, `staging.yaml` and `prod.yaml` hold only what differs. Argo CD layers them in that order over the chart's defaults in `apps/orders-gateway/chart/values.yaml`.

Each environment is an Argo CD Application, `orders-gateway-<env>`, in a namespace of the same name. The ApplicationSet in `stack/bootstrap/apps/templates/apps.yaml` generates them. Every object is named `orders-gateway`, so other apps can share the namespace.

| | dev | staging | prod |
| --- | --- | --- | --- |
| Replicas | 1 | 2 | 3, HPA up to 6 on CPU |
| Disruption budget and spreading | no | yes | yes |
| URL | <http://localhost:8082> | <http://localhost:8083> | <http://localhost:8080> |
| Sync | automatic | click Sync in Argo CD, or `--sync` | click Sync in Argo CD, or `--sync` |

Each port also answers on `http://orders-gateway.localhost:<port>`.

## Versions

An env file pins a published `version`, for example `version: 1.2.0`. That means image `localhost:30500/orders-gateway:1.2.0` and chart `orders-gateway` 1.2.0, both from the in-cluster registry (`stack/registry/`).

- `./pipeline ci orders-gateway --version 1.2.0` publishes a version.
- `./pipeline cd orders-gateway <env> --version 1.2.0` sets it in the env file. Staging only takes a version dev has run, and prod only one staging has run.
- Without a `version` (a dev-only build), dev renders `apps/orders-gateway/chart/` as it is in Git.
- A fresh cluster starts on 0.1.0, which `./platform up` builds from the checkout.

## Auto-sync

`autoSync` in each file sets it: `true` in `dev.yaml`, `false` in `staging.yaml` and `prod.yaml`. With `true`, Argo CD applies each change and `./pipeline cd` waits for the rollout. With `false`, `./pipeline cd` pushes the change and stops. You then click Sync on `orders-gateway-<env>` in Argo CD (<http://localhost:8081>), or pass `--sync`.

## Try it

```sh
curl localhost:8082/version
curl -X POST localhost:8082/echo -d '{"hello":"dev"}'
```
