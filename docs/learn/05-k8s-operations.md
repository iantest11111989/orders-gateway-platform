# 5. Kubernetes operations: Argo CD, rolling updates and Kyverno

**Time:** about 15 minutes. **You need:** a running stack. Exercises 1 and 2 help.

By the end you will be able to read the controllers that run this platform, each through its own UI or CLI and through its metrics in Grafana:
- **Argo CD** keeps the cluster equal to Git.
- **The Deployment controller** replaces pods one at a time on a release.
- **Kyverno** decides what's allowed to run.

Grafana is <http://localhost:3000> (`admin` / `admin12345`); the other logins are printed by `./platform urls`.

## 1. Argo CD: Git is the truth (5 min)

1. Open <http://localhost:8081> and log in as `admin` / `admin12345`. Each tile is an **Application**: a folder or chart in Git, deployed to one namespace. Open `dev` to see the tree of everything it created (Deployment, ReplicaSet, Pods, Service, HTTPRoute...).
2. In Grafana, open the **Argo CD** dashboard (<http://localhost:3000/d/argocd>). **Out of sync** and **Not healthy** should both be 0, and **Every Application** lists the same apps as the tiles, from the `argocd_app_info` metric.
3. Now change something behind Argo CD's back:

   ```sh
   ./platform shell
   kubectl -n dev scale deploy orders-gateway --replicas=2
   kubectl -n dev get deploy orders-gateway -w
   ```

   Within seconds `replicas` goes back to `1`. On the local cluster it took 5 seconds. Argo CD saw the live state drift from Git (dev runs one replica, `cd/orders-gateway/dev.yaml`) and **self-healed** it. Press Ctrl-C. In the UI, `dev`'s **History and rollback** and the dashboard's **Syncs per Application** panel show the extra sync.

That's the rule for this whole platform: **change Git, not the cluster.** A manual change lasts seconds.

## 2. A rolling update, step by step (5 min)

Every environment runs a plain Deployment named after its app (`orders-gateway`). A new image replaces its pods one at a time: `maxSurge: 1` adds one new pod, and `maxUnavailable: 0` removes an old one only once the new one is Ready.

1. Start the rolling-update demo in one terminal (`./platform demo rolling-update`, about 2 minutes). It makes a 3-pod copy of dev in namespace `demo` and moves it from v1 to v2 under k6 traffic.
2. In a second terminal, watch the ReplicaSets:

   ```sh
   ./platform shell
   kubectl -n demo get rs -l app.kubernetes.io/name=orders-gateway -w
   ```

   The new ReplicaSet goes 1 → 2 → 3 while the old one goes 3 → 2 → 1 → 0, and the total never drops below 3 ready pods. Press Ctrl-C when the old one reaches 0.
3. See the history Kubernetes keeps:

   ```sh
   kubectl -n demo rollout history deploy/orders-gateway
   ```

   Each revision is a ReplicaSet. `kubectl rollout undo` would go back one, but here Argo CD would undo *that* within seconds, which is why `./platform rollback` changes Git instead.
4. In Grafana's **orders-gateway** dashboard (environment `demo`), **Pods by version** shows v1 handing over to v2, with a marker at the change, and the 5xx panels stay at 0.

## 3. Kyverno: what's allowed to run (5 min)

Kyverno checks every pod at admission. In the app namespaces (`dev`, `staging`, `prod`, `demo`), `:latest` images and unsigned app images are **refused**. Everywhere, the other policies only **audit**: they report, they don't block.

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
- A release makes 5% of requests fail. What tells you it was the release, and how do you undo it?
- Why do the `:latest` pods behave differently in `default` and in `dev`?

That's the end of the track. Go back to the [index](README.md), or break something with `./platform demo <name>` and find out why using what you've learned.
