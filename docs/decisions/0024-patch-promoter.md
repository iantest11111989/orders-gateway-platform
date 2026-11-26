# 0024: An in-cluster patch promoter, a pause file and an order trickle

**Status:** Accepted, 2026-11-25

## Context

The brief (section 10) asks that small security and dependency patches move from dev to staging to prod on their own. Each one soaks for about an hour first, and only moves on when the SLO holds, no alerts fire and the health checks pass. There must be one pause switch and a clear record of every promotion. Feature changes keep needing the owner's approval.

What already exists:
- **Classification:** CI opens promotion PRs `promote/staging` and `promote/prod` for every image dev gets, and tags each commit with what it ships: `Promotion-Kind: patch | feature | unknown` (decision 0015, `scripts/promotion-kind.sh`). It's a patch only if every image-changing commit in the range is a Renovate PR labelled `dependencies` and not `needs-owner-approval`.
- **Canary:** prod goes through the Argo Rollouts canary, which rolls back on its own (decision 0011).

What's missing is something that reads the gates from the cluster and merges.

## Choice: pull, from inside the cluster

GitHub's hosted runners can't reach a kind cluster on a laptop, and a self-hosted runner or a tunnel would need the owner to set up and secure more. So the cluster checks the gates itself and calls GitHub, outbound only:
- **`promoter` CronJob, every 10 minutes** (`gitops/manifests/promoter/`, `scripts/promoter.py run`). For each open promotion PR it checks the gates below, writes them as a table to **one comment on the PR** (edited in place), and merges the PR when every gate passes. The merge commit carries the same table. That comment and commit are the record (brief step 6).
- **Read-only in the cluster:** `get` on the three orders Applications in Argo CD and `list` pods in orders-dev and orders-staging, plus Prometheus (one NetworkPolicy, `allow-promoter-to-prometheus`). The only thing that can change anything is the GitHub token.
- **Python standard library on `python:3.14-alpine`** (78 MB, pinned by digest; Renovate keeps it current through its kubernetes manager). The toolbox image is 1.5 GB, too big to pull into the cluster for this. `scripts/promoter_test.py` tests every gate without a cluster.

## The gates

For staging the environment before is dev, and for prod it's staging. All of them must pass, in this order:

| Gate | Why |
| --- | --- |
| `promotion/PAUSED` isn't on main | the pause switch |
| the newest push to the PR's branch is its head and came from `github-actions[bot]` (GitHub's repository activity) | the bots share one GitHub account, so a commit's author and its `Promotion-Kind` trailer could be written by anyone; who pushed it can't be |
| `Promotion-Kind: patch` | features need the owner |
| the PR's checks all finished and passed | the PR's own CI, on the branch head |
| the environment before ran **only** that image for 60 minutes (58 of the last 60 one-minute samples of `app_build_info`) | a newer image, or a rollback, starts the soak again |
| it served at least 300 requests in that hour | an SLO with no traffic proves nothing |
| its availability and latency SLOs held over the last hour (`slo:orders_*_errors:ratio_rate1h` ≤ 0.5%, no NaN) | the brief's "SLO holds" |
| no alert fired for it during the soak, and none is firing for the target | "no alerts fire" |
| its pods are all Ready and labelled with that version, and Argo CD shows both environments Synced and Healthy | what `./platform verify` checks |

It does at most one promotion per pass. After staging is promoted, prod's PR waits until staging has soaked the same image for an hour. The merge passes the PR's head SHA, so GitHub refuses it if the branch moved after the check.

## The pause switch

A file, **`promotion/PAUSED`**, on main. Commit it to stop all automatic promotion and delete it to resume. It **fails closed**: only a clear 404 counts as "not paused". Any other answer, such as a 5xx or a rate limit, ends the pass without promoting anything. It's a file because a file is visible in Git, works the same in a fork, and leaves its own record. Promotion PRs stay open while paused, and their comment says why.

## The order trickle

dev and staging get no traffic unless someone runs k6, so an hour's SLO would be vacuous. The `trickle` Deployment in the same namespace sends a steady trickle of orders to each environment, including prod. It sends one round to all three every `TRICKLE_INTERVAL` (0.5 s), plus the time the requests take, over kept-alive connections through the gateway with each environment's hostname, the way a client would. The orders use `customer_id` `cust-trickle`, so they're easy to filter. Prod gets traffic too because its canary analysis needs requests at the 10% step, or it pauses (decision 0011). The pod uses about 10m CPU and 15 MiB.

The trickle is always on, so **dev's rates read higher than k6 alone**, and the `docs/learn` exercises' expected numbers come out higher by the trickle's rate (`docs/learn/README.md` says so).

## Setup: a GitHub token, which only the owner can create

Without a token the promoter is a **dry run**: it reads the public repo and logs the gate table, which you can see in Loki with `{namespace="promoter"}`. It changes nothing. To go live, create a fine-grained token for this repository only, with **Contents: read and write**, **Pull requests: read and write** and **Deployments: read and write** (the last one so it can show Argo CD's syncs on GitHub, decision 0033), and store it in the cluster:

```sh
./platform shell
read -rs T && kubectl -n promoter create secret generic promoter-github --from-literal=token="$T"; unset T
```

It's a plain Secret created by hand, **not in Git**. The Sealed Secrets key here is a committed demo key (decision 0018), so anything sealed with it is public. It doesn't survive `./platform down`, so create it again after a new cluster. In production it would come from a vault through External Secrets, or be a GitHub App installation token.

## Trade-offs

- **The trickle is synthetic traffic.** A real deployment would soak on real traffic and might need a longer soak at night.
- **A merge through a personal token runs the PR's workflows**, unlike one made with `GITHUB_TOKEN`. That's wanted: main's push workflows run as after any merge.
- **10-minute passes** mean a promotion lands up to 10 minutes after its gates pass. That's fine next to a 60-minute soak.
- **The trickle doesn't restart when `script.yaml` changes** (the CronJob reads the script fresh on every run). Restart it with `kubectl -n promoter rollout restart deploy/trickle`.
