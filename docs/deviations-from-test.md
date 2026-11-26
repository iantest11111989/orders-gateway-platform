# Deviations from the brief

Where this repo knowingly does something other than the brief asked, and why.

## Deployments are named after their app, not `app`

**The brief:** each environment runs a Deployment named `app`.

**Here:** the Deployment, and every other object the chart makes (Service, HPA, PDB, NetworkPolicy, Ingress), is named after the app: `orders-gateway`. Its pods are labelled `app.kubernetes.io/name=orders-gateway`, and its metrics carry `service="orders-gateway"` and `job="orders-gateway"`.

**Why:** the repo is a practice tool for CI/CD with more than one app. `./platform demo hello-world` takes a second app through the same `./pipeline` into the same dev, staging and prod namespaces. Two Deployments called `app` in one namespace are impossible, and a shared name would mix both apps' metrics, logs and alerts. Naming objects after the app keeps them apart, and it's what a real multi-app platform does.

**What follows from it:**
- The SLO rules count only `service="orders-gateway"`, and their alerts carry `namespace` and `service`. So the promotion gate (`scripts/promotion-gate.sh`) refuses to promote an app while one of its own alerts fires, and another app's errors don't block it.
- Commands in the docs and runbooks use `deploy/orders-gateway`, and Loki queries use `{app="orders-gateway"}`.
- Plain `http://localhost:<port>` still reaches orders-gateway. Each app also has its own host, `http://<app>.localhost:<port>`.
- An existing cluster moves over without downtime: the apps' Applications sync with `PruneLast=true`, so the old `app` objects are removed only after the new ones are healthy.
