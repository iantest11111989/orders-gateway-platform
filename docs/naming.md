# Objects are named after their app

**The usual starting point:** each environment runs a single Deployment named `app`.

**Here:** the Deployment, and every other object the chart makes, is named after the app: `orders-gateway`. Pods carry the label `app.kubernetes.io/name=orders-gateway`, and metrics carry `service="orders-gateway"` and `job="orders-gateway"`.

**Why:** the repo is for practising CI/CD with more than one app. `./platform demo hello-world` takes a second app through the same `./pipeline` into the same namespaces. Two Deployments called `app` can't share a namespace, and a shared name would mix the apps' metrics, logs and alerts.

**What follows:**

- The SLO rules count only `service="orders-gateway"`, and their alerts carry `namespace` and `service`. So the promotion gate (`scripts/promotion-gate.sh`) blocks an app only on its own alerts.
- Docs and runbooks use `deploy/orders-gateway`, and Loki queries use `{app="orders-gateway"}`.
- Plain `http://localhost:<port>` still reaches orders-gateway. Each app also has its own host, `http://<app>.localhost:<port>`.
- The app Applications sync with `PruneLast=true`, so on an existing cluster the old `app` objects are removed only after the new ones are healthy.
