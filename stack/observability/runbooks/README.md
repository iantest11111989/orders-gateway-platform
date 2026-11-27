# runbooks

One runbook per alert in `stack/observability/alerts/`, named after the alert. Each has the same parts: what it means, Check, Fix, Done when.

- Run `kubectl` and `argocd` inside `./platform shell`, or as `./platform kubectl ...`.
- URLs and logins: `./platform urls`. Argo CD http://localhost:8081, Grafana http://localhost:3000, Prometheus http://localhost:9090, Alertmanager http://localhost:9093.
- Fix through Git. Argo CD self-heal reverts a manual `kubectl edit`.
- Argo CD syncs from the in-stack Git server. After you edit a file, push the checkout there with `./platform shell scripts/git-sync.sh`. dev and the platform components then sync by themselves; staging and prod need Sync in Argo CD.
