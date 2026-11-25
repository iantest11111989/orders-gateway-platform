# 5. Kubernetes operations: Argo CD, Rollouts and Kyverno

**Time:** about 15 minutes. **You need:** a running stack. Exercises 1 and 2 help.

By the end you will be able to read the three controllers that run this platform, each through its own UI or CLI and through its metrics in Grafana:
- **Argo CD** keeps the cluster equal to Git.
- **Argo Rollouts** runs prod's canary.
- **Kyverno** decides what's allowed to run.

Grafana is <http://localhost:3000> (`admin` / `admin12345`); the other logins are printed by `./platform urls`.

## 1. Argo CD: Git is the truth (5 min)

1. Open <https://argocd.localtest.me> and log in as `admin`. Each tile is an **Application**: a folder or chart in Git, deployed to one namespace. Open `dev` to see the tree of everything it created (Deployment, ReplicaSet, Pods, Service, HTTPRoute...).
2. In Grafana, open the **Argo CD** dashboard (<http://localhost:3000/d/argocd>). **Out of sync** and **Not healthy** should both be 0, and **Every Application** lists the same apps as the tiles, from the `argocd_app_info` metric.
3. Now change something behind Argo CD's back:

   ```sh
   ./platform shell
   kubectl -n dev scale deploy orders-gateway --replicas=2
   kubectl -n dev get deploy orders-gateway -w
   ```

   Within seconds `replicas` goes back to `1`. On ogp it took 5 seconds. Argo CD saw the live state drift from Git (dev runs one replica, `environments/dev/values.yaml`) and **self-healed** it. Press Ctrl-C. In the UI, `dev`'s **History and rollback** and the dashboard's **Syncs per Application** panel show the extra sync.

That's the rule for this whole platform: **change Git, not the cluster.** A manual change lasts seconds.

## 2. Argo Rollouts: the canary (5 min)

prod runs a plain Deployment named `app` (the assignment's contract, [decision 0026](../decisions/0026-compose-entrypoint.md)). The canary lives in the **demo** copy of prod: a **Rollout** moves traffic to a new version in steps and checks the SLO at each one ([decision 0011](../decisions/0011-canary-rollouts.md)).

1. Start the canary demo (`./platform demo canary`, about 6 minutes), then in the shell:

   ```sh
   kubectl argo rollouts -n demo get rollout app
   ```

   You see the status (`Healthy`), the steps (`Step: 6/6`, `SetWeight: 100`), which image is `stable`, and the ReplicaSets per revision.
2. Look at the check that gates each step:

   ```sh
   kubectl -n demo get analysistemplate app-slo -o yaml
   ```

   Two Prometheus queries, `error-ratio` (at most 0.5%) and `p99-latency` (at most 0.3 s), run only against the **canary's** pods (`rollouts_pod_template_hash`). They're measured 4 times, 30 seconds apart, after a 60-second warm-up. `failureLimit: 1` allows one failed measurement, so a second one fails the analysis: Rollouts aborts the canary and sends all traffic back to the stable version. `inconclusiveLimit: 1` does the same for missing data (no canary traffic): a second inconclusive result pauses the canary instead of guessing. They're the same SLO thresholds as exercise 4, applied to the new version alone.
3. In Grafana, open the **Argo Rollouts** dashboard (<http://localhost:3000/d/argo-rollouts>). **Rollouts now** shows `app` in `demo` as `Completed`. **Recent analysis runs** and **Analysis metrics** list the runs from the last canary, each `Successful`. The live, step-by-step view is the Rollouts dashboard at <https://rollouts.localtest.me>. It's read-only: promote or abort with `kubectl argo rollouts promote|abort`.

To see a canary abort, run `./platform demo canary-fail` next (about 5 minutes), with both dashboards open.

## 3. Kyverno: what's allowed to run (5 min)

Kyverno checks every pod at admission ([decisions 0012](../decisions/0012-kyverno-policies.md) and [0022](../decisions/0022-enforce-in-orders.md)). In the app namespaces (`dev`, `staging`, `prod`, `demo`), `:latest` images and unsigned app images are **refused**. Everywhere, the other policies only **audit**: they report, they don't block.

1. Ask the API server to create a `:latest` pod without actually creating it (`--dry-run=server` still runs admission):

   ```sh
   kubectl -n default run try-latest --image=docker.io/library/busybox:latest --restart=Never --dry-run=server -o name
   ```

   It's **admitted** (`pod/try-latest`). `default` isn't an app namespace (`dev`, `staging`, `prod`, `demo`), so `disallow-latest-tag-platform` only audits it.
2. Now ask for the same image in an app namespace. The pod meets Pod Security `restricted`, which the app namespaces also enforce and which the API server checks before Kyverno. It also meets the Audit policies, so it doesn't add findings to the table in step 4. The image is its only problem:

   ```sh
   kubectl -n dev run try-latest --image=docker.io/library/busybox:latest --restart=Never --dry-run=server -o name --overrides='{
     "apiVersion": "v1",
     "spec": {"securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "try-latest", "image": "docker.io/library/busybox:latest",
         "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
         "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"memory": "32Mi"}}}]}}'
   ```

   It's **refused**: `Policy disallow-latest-tag failed: Images must not use the latest tag`. (`./platform verify` runs this same check, and `./platform demo policy` shows the signature policy too.)
3. See what Audit finds without blocking:

   ```sh
   kubectl get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail
   ```

   For example, Grafana's sidecars have no probes (`require-probes`). Those are third-party charts that would need an exception before that policy could move to Enforce.
4. In Grafana, open the **Kyverno** dashboard (<http://localhost:3000/d/kyverno>). **Pods refused (24 h)** went up by one from step 2. **Failures by policy and namespace** is the table to read when deciding which policy is clean enough to enforce next: a policy that stays at 0 outside the test namespaces is ready.

## Check yourself

- You `kubectl edit` a ConfigMap in `staging` to change a setting. What happens, and what should you have done?
- A prod canary aborts. Where do you look first to see which check failed?
- Why do the `:latest` pods behave differently in `default` and in `dev`?

That's the end of the track. Go back to the [index](README.md), or break something with `./platform demo <name>` and find out why using what you've learned.
