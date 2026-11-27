# 5. Kubernetes operations: Argo CD, rolling updates and Kyverno

Time: about 15 minutes. You need a running stack. Exercises 1 and 2 help.

You'll watch three controllers at work, each in its own UI and in Grafana:

- Argo CD keeps the cluster equal to Git.
- The Deployment controller replaces pods one at a time.
- Kyverno decides what may run.

## 1. Argo CD: Git is the truth

1. Open <http://localhost:8081> (`admin` / `admin12345`). Each tile is an Application. Open `orders-gateway-dev` to see what it created: Deployment, ReplicaSet, Pods, Service, Ingress.
2. Open Grafana's Argo CD dashboard (<http://localhost:3000/d/argocd>). Out of sync and Not healthy should both be 0.
3. Change something behind Argo CD's back:

   ```sh
   ./platform shell
   kubectl -n dev scale deploy orders-gateway --replicas=2
   kubectl -n dev get deploy orders-gateway -w
   ```

   Within seconds it's back to 1, the value in `apps/orders-gateway/cd/dev.yaml`. Argo CD saw the drift and self-healed. Press Ctrl-C. The Syncs per Application panel shows the extra sync.

The rule: change Git, not the cluster.

## 2. A rolling update

The Deployment uses `maxSurge: 1` and `maxUnavailable: 0`: it adds one new pod, and removes an old one only when the new one is Ready.

1. In one terminal, run `./platform demo rolling-update`. It makes a 3-pod copy of dev in namespace `demo` and moves it from v1 to v2 under traffic.
2. In a second terminal, watch the ReplicaSets:

   ```sh
   ./platform shell
   kubectl -n demo get rs -l app.kubernetes.io/name=orders-gateway -w
   ```

   The new one goes 1, 2, 3 while the old one goes 3, 2, 1, 0. Ready pods never drop below 3.
3. See the history:

   ```sh
   kubectl -n demo rollout history deploy/orders-gateway
   ```

   Each revision is a ReplicaSet. `kubectl rollout undo` would be reverted by Argo CD, which is why `./pipeline rollback` changes Git.
4. In Grafana's orders-gateway dashboard (environment `demo`), Pods by version shows v1 handing over to v2, and the 5xx panel stays at 0.

## 3. Kyverno: what may run

In the app namespaces (`dev`, `staging`, `prod`, `demo`), Kyverno refuses `:latest` images and unsigned app images. Elsewhere, policies only audit: they report but don't block.

1. Try a `:latest` pod in `default`. `--dry-run=server` runs admission without creating anything:

   ```sh
   kubectl -n default run try-latest --image=docker.io/library/busybox:latest --restart=Never --dry-run=server -o name
   ```

   It's admitted. `disallow-latest-tag-platform` only audits outside the app namespaces.

2. Try the same image in `dev`. The overrides make the pod pass Pod Security `restricted` and the audit policies, so the image tag is its only problem:

   ```sh
   kubectl -n dev run try-latest --image=docker.io/library/busybox:latest --restart=Never --dry-run=server -o name --overrides='{
     "apiVersion": "v1",
     "spec": {"securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
       "containers": [{"name": "try-latest", "image": "docker.io/library/busybox:latest",
         "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
         "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"memory": "32Mi"}}}]}}'
   ```

   It's refused by `disallow-latest-tag`: "Images must not use the latest tag". `./platform demo policy` also shows the signature policy.

3. See what audit finds:

   ```sh
   kubectl get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail
   ```

   For example, `require-probes` flags third-party sidecars with no probes.

4. Open Grafana's Kyverno dashboard (<http://localhost:3000/d/kyverno>). Pods refused (24 h) went up by one. Failures by policy and namespace (24 h) shows which audit policy is clean enough to enforce next.

## Check yourself

- You `kubectl edit` a ConfigMap in `staging`. What happens, and what should you do instead?
- A release makes 5% of requests fail. How do you know it was the release, and how do you undo it?
- Why is the `:latest` pod admitted in `default` but refused in `dev`?

That's the end. Go back to the [index](README.md), or run `./platform demo <name>` and work out what happened.
