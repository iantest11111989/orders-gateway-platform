#!/usr/bin/env python3
"""Unit tests for scripts/promoter.py, without a cluster or GitHub: python3 scripts/promoter_test.py"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import promoter  # noqa: E402

TAG = "sha-0123456789ab"


def pr():
    return {"number": 7, "title": f"Promote staging to {TAG}", "head": {"sha": "abc", "ref": "promote/staging"}}


def fake_github(kind="patch", runs=None, subject=f"staging: orders-gateway {TAG}", pusher="github-actions[bot]", pushed="abc"):
    if runs is None:
        runs = [{"name": "full-up", "status": "completed", "conclusion": "success"}]

    def gh(method, path, body=None):
        if path.startswith("/activity?ref=refs/heads/promote/staging"):
            return [{"after": pushed, "actor": {"login": pusher}}]
        if path.endswith("/check-runs?per_page=100"):
            return {"check_runs": runs}
        if path.startswith("/commits/"):
            return {"commit": {"message": f"{subject}\n\nPromotion-Range: a..b\nPromotion-Kind: {kind}\n"}}
        raise AssertionError(path)
    return gh


def fake_prometheus(minutes=60, served=1800, avail=0.0, latency=0.001, fired=(), firing=()):
    def prom(q):
        if q.startswith("count_over_time"):
            return [({}, minutes)] if minutes is not None else []
        if q.startswith("sum(increase"):
            return [({}, served)]
        if "availability" in q:
            return [({}, avail)] if avail is not None else []
        if "latency" in q:
            return [({}, latency)]
        if "max_over_time(ALERTS" in q:
            return [({"alertname": a}, 1) for a in fired]
        if "ALERTS" in q:
            return [({"alertname": a}, 1) for a in firing]
        raise AssertionError(q)
    return prom


def fake_kube(ready=True, version=TAG, sync="Synced", health="Healthy"):
    def kube(path):
        if "/pods" in path:
            return {"items": [{"metadata": {"labels": {"app.kubernetes.io/version": version}},
                               "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}}]}
        return {"status": {"sync": {"status": sync}, "health": {"status": health}}}
    return kube


def evaluate(paused=False, gh=None, prom=None, kube=None):
    return promoter.evaluate("staging", pr(), paused,
                             gh or fake_github(), prom or fake_prometheus(), kube or fake_kube())


def failing(gates):
    return [name for name, ok, _ in gates if not ok]


class Gates(unittest.TestCase):
    def test_all_pass(self):
        tag, gates = evaluate()
        self.assertEqual(tag, TAG)
        self.assertEqual(failing(gates), [])
        self.assertEqual(len(gates), 11)

    def test_queries_use_the_apps_metrics(self):
        # app/server.js exports app_info{version} and http_requests_total{route,method,status};
        # the soak counts only the SLIs' routes (decision 0027) in the previous environment.
        seen, kube_paths = [], []
        prom = fake_prometheus()
        evaluate(prom=lambda q: seen.append(q) or prom(q),
                 kube=lambda p: kube_paths.append(p) or fake_kube()(p))
        joined = "\n".join(seen)
        self.assertIn('app_info{namespace="dev",version="%s"}' % TAG, joined)
        self.assertIn('http_requests_total{namespace="dev",route=~"/work|/echo"}', joined)
        self.assertNotIn("app_build_info", joined)
        self.assertIn("/api/v1/namespaces/dev/pods?labelSelector=app.kubernetes.io%2Fname%3Dapp", kube_paths)

    def test_paused(self):
        _, gates = evaluate(paused=True)
        self.assertEqual(failing(gates), ["automatic promotion not paused"])
        self.assertEqual(len(gates), 4, "cluster gates are skipped when a cheap gate fails")

    def test_feature_needs_the_owner(self):
        for kind in ("feature", "unknown"):
            _, gates = evaluate(gh=fake_github(kind=kind))
            self.assertEqual(failing(gates), ["ships only patches"])

    def test_missing_trailer_is_not_a_patch(self):
        gh = fake_github()
        _, gates = evaluate(gh=lambda m, p, b=None: {"commit": {"message": f"staging: orders-gateway {TAG}\n\nno trailers"}} if p == "/commits/abc" else gh(m, p))
        self.assertEqual(failing(gates), ["ships only patches"])

    def test_pause_fails_closed(self):
        self.assertFalse(promoter.is_paused(lambda m, p: (404, None)))
        self.assertTrue(promoter.is_paused(lambda m, p: (200, {})))
        for status in (403, 429, 500, 502):
            with self.assertRaises(RuntimeError):
                promoter.is_paused(lambda m, p, s=status: (s, None))

    def test_only_ci_pushes_count(self):
        _, gates = evaluate(gh=fake_github(pusher="iantest11111989"))
        self.assertEqual(failing(gates), ["the PR's commit was pushed by CI"], "a bot pushing a 'patch' trailer by hand")
        _, gates = evaluate(gh=fake_github(pushed="def"))
        self.assertEqual(failing(gates), ["the PR's commit was pushed by CI"], "the branch moved after CI's push")
        self.assertEqual(promoter.pushed_by_ci([], "abc")[0], False)

    def test_checks(self):
        self.assertEqual(promoter.checks_gate({"check_runs": []})[0], False)
        running = [{"name": "a", "status": "in_progress", "conclusion": None}]
        self.assertEqual(promoter.checks_gate({"check_runs": running}), (False, "still running: a"))
        failed = running + [{"name": "b", "status": "completed", "conclusion": "failure"}]
        self.assertEqual(promoter.checks_gate({"check_runs": failed}), (False, "failed: b"))
        skipped = [{"name": "a", "status": "completed", "conclusion": "skipped"}]
        self.assertEqual(promoter.checks_gate({"check_runs": skipped})[0], True)

    def test_soak_too_short(self):
        _, gates = evaluate(prom=fake_prometheus(minutes=40))
        self.assertEqual(failing(gates), ["dev has run only sha-0123456789ab for 60 min"])
        _, gates = evaluate(prom=fake_prometheus(minutes=None))
        self.assertIn("dev has run only sha-0123456789ab for 60 min", failing(gates))

    def test_two_missed_scrapes_are_allowed(self):
        _, gates = evaluate(prom=fake_prometheus(minutes=58))
        self.assertEqual(failing(gates), [])

    def test_no_traffic(self):
        _, gates = evaluate(prom=fake_prometheus(served=12))
        self.assertEqual(failing(gates), ["dev served at least 300 requests"])

    def test_slo(self):
        _, gates = evaluate(prom=fake_prometheus(avail=0.02))
        self.assertEqual(failing(gates), ["dev availability SLO held over 1 h"])
        _, gates = evaluate(prom=fake_prometheus(avail=float("nan")))
        self.assertEqual(failing(gates), ["dev availability SLO held over 1 h"], "NaN (no data) doesn't pass")
        _, gates = evaluate(prom=fake_prometheus(avail=None))
        self.assertEqual(failing(gates), ["dev availability SLO held over 1 h"])

    def test_alerts(self):
        _, gates = evaluate(prom=fake_prometheus(fired=["OrdersGatewayAvailabilityFastBurn"]))
        self.assertEqual(failing(gates), ["no alerts for dev in the soak, none firing for staging"])
        _, gates = evaluate(prom=fake_prometheus(firing=["OrdersGatewayLatencySlowBurn"]))
        detail = [d for n, ok, d in gates if not ok][0]
        self.assertEqual(detail, "staging: OrdersGatewayLatencySlowBurn")

    def test_pods_and_argo(self):
        _, gates = evaluate(kube=fake_kube(ready=False))
        self.assertEqual(failing(gates), ["dev pods Ready on sha-0123456789ab"])
        _, gates = evaluate(kube=fake_kube(version="sha-ffffffffffff"))
        self.assertEqual(failing(gates), ["dev pods Ready on sha-0123456789ab"])
        _, gates = evaluate(kube=fake_kube(health="Progressing"))
        self.assertEqual(failing(gates), ["Argo CD Synced and Healthy"])

    def test_subject_without_tag(self):
        tag, gates = evaluate(gh=fake_github(subject="Update staging by hand"))
        self.assertEqual(tag, "?")
        self.assertIn("image tag in the commit subject", failing(gates))


VALUES = """# prod
env: prod

image:
  tag: sha-feedfacecafe
  digest: sha256:abc
replicas: 3
"""


def fake_deploy_world(sync="Synced", health="Healthy", rev="r2", latest_sha="r1", latest_state="success"):
    """A fake GitHub + Kubernetes for report_environment; records writes."""
    import base64
    writes = []

    def kube_get(path):
        return {"status": {"sync": {"status": sync, "revision": rev}, "health": {"status": health}}}

    def gh(method, path, body=None):
        if method == "GET" and path.startswith("/contents/environments/"):
            assert path.endswith(f"?ref={rev}"), path
            return {"content": base64.b64encode(VALUES.encode()).decode()}
        if method == "GET" and path.startswith("/deployments?environment="):
            return [{"id": 41, "sha": latest_sha}] if latest_sha else []
        if method == "GET" and path == "/deployments/41/statuses?per_page=1":
            return [{"state": latest_state}] if latest_state else []
        if method == "POST" and path == "/deployments":
            writes.append(("deployment", body))
            return {"id": 42}
        if method == "POST" and path.endswith("/statuses"):
            writes.append((path, body))
            return {}
        raise AssertionError((method, path))
    return gh, kube_get, writes


class Deployments(unittest.TestCase):
    def setUp(self):
        self.token = promoter.TOKEN
        promoter.TOKEN = "t"

    def tearDown(self):
        promoter.TOKEN = self.token

    def test_state_mapping(self):
        self.assertEqual(promoter.deploy_state("Synced", "Healthy"), "success")
        self.assertEqual(promoter.deploy_state("Synced", "Degraded"), "failure")
        self.assertEqual(promoter.deploy_state("OutOfSync", "Healthy"), "in_progress")
        self.assertEqual(promoter.deploy_state("Synced", "Progressing"), "in_progress")
        self.assertIsNone(promoter.deploy_state("Unknown", "Missing"))

    def test_values_tag(self):
        self.assertEqual(promoter.values_tag(VALUES), "sha-feedfacecafe")
        self.assertEqual(promoter.values_tag('image:\n  repository: x\n  tag: "local-1"\n'), "local-1")
        self.assertIsNone(promoter.values_tag("replicas: 1\n"))

    def test_new_revision_creates_a_deployment(self):
        gh, kube_get, writes = fake_deploy_world(rev="r2", latest_sha="r1")
        out = promoter.report_environment("prod", gh, kube_get)
        self.assertEqual(writes[0][0], "deployment")
        dep = writes[0][1]
        self.assertEqual((dep["ref"], dep["environment"], dep["description"]), ("r2", "prod", "sha-feedfacecafe"))
        self.assertTrue(dep["production_environment"])
        self.assertEqual(writes[1], ("/deployments/42/statuses", {
            "state": "success", "description": "Argo CD Synced/Healthy: sha-feedfacecafe",
            "environment": "prod", "auto_inactive": True}))
        self.assertIn("deployment: success", out)

    def test_same_revision_new_state_adds_only_a_status(self):
        gh, kube_get, writes = fake_deploy_world(health="Degraded", rev="r1", latest_sha="r1", latest_state="success")
        promoter.report_environment("staging", gh, kube_get)
        self.assertEqual([w[0] for w in writes], ["/deployments/41/statuses"])
        self.assertEqual(writes[0][1]["state"], "failure")

    def test_nothing_changed_writes_nothing(self):
        gh, kube_get, writes = fake_deploy_world(rev="r1", latest_sha="r1", latest_state="success")
        self.assertIn("unchanged", promoter.report_environment("dev", gh, kube_get))
        self.assertEqual(writes, [])

    def test_unknown_state_is_skipped(self):
        gh, kube_get, writes = fake_deploy_world(sync="Unknown", health="Missing")
        self.assertIn("skipped", promoter.report_environment("dev", gh, kube_get))
        self.assertEqual(writes, [])

    def test_dry_run_writes_nothing(self):
        promoter.TOKEN = ""
        gh, kube_get, writes = fake_deploy_world(rev="r2", latest_sha="r1")
        self.assertIn("dry run", promoter.report_environment("prod", gh, kube_get))
        self.assertEqual(writes, [])

    def test_a_token_without_the_permission_does_not_stop_the_pass(self):
        def gh(method, path, body=None):
            raise RuntimeError(f"GitHub {method} {path}: HTTP 403: Resource not accessible")
        lines = []
        log, promoter.log = promoter.log, lines.append
        try:
            promoter.report_deployments(gh, lambda p: {"status": {"sync": {"status": "Synced", "revision": "r"},
                                                                   "health": {"status": "Healthy"}}})
        finally:
            promoter.log = log
        self.assertEqual(len(lines), 3)
        self.assertTrue(all("Deployments: read and write" in line for line in lines))

    def test_network_errors_do_not_stop_the_pass(self):
        def gh(method, path, body=None):
            raise OSError("timed out")
        lines = []
        log, promoter.log = promoter.log, lines.append
        try:
            promoter.report_deployments(gh, lambda p: {"status": {"sync": {"status": "Synced", "revision": "r"},
                                                                   "health": {"status": "Healthy"}}})
            promoter.report_deployments(lambda *a: {}, lambda p: {})  # odd payloads: KeyError-free, skipped
        finally:
            promoter.log = log
        self.assertEqual(len([line for line in lines if "timed out" in line]), 3)

    def test_without_a_token_nothing_is_called(self):
        promoter.TOKEN = ""

        def boom(*a, **k):
            raise AssertionError("no GitHub or cluster calls without a token")
        lines = []
        log, promoter.log = promoter.log, lines.append
        try:
            promoter.report_deployments(boom, boom)
        finally:
            promoter.log = log
        self.assertEqual(len(lines), 1)


class Parsing(unittest.TestCase):
    def test_trailer(self):
        msg = "x\n\nPromotion-Range: a..b\nPromotion-Kind: patch\n"
        self.assertEqual(promoter.trailer(msg, "Promotion-Kind"), "patch")
        self.assertIsNone(promoter.trailer(msg, "Promotion-Feature-PRs"))

    def test_image_tag(self):
        self.assertEqual(promoter.image_tag("prod: orders-gateway sha-0123456789ab\n\nImage ..."), "sha-0123456789ab")
        self.assertEqual(promoter.image_tag("Promote prod to sha-0123456789ab"), None)
        self.assertEqual(promoter.image_tag("dev: orders-gateway sha-0123456789ab"), None)

    def test_table(self):
        out = promoter.table([("a", True, "1"), ("b", False, "2")])
        self.assertIn("| a | ✅ | 1 |", out)
        self.assertIn("| b | ❌ | 2 |", out)


if __name__ == "__main__":
    unittest.main()
