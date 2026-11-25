#!/usr/bin/env python3
"""Unit tests for scripts/promoter.py, without a cluster or GitHub: python3 scripts/promoter_test.py"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import promoter  # noqa: E402

TAG = "sha-0123456789ab"


def pr():
    return {"number": 7, "title": f"Promote staging to {TAG}", "head": {"sha": "abc"}}


def fake_github(kind="patch", runs=None, subject=f"staging: orders-gateway {TAG}"):
    if runs is None:
        runs = [{"name": "full-up", "status": "completed", "conclusion": "success"}]

    def gh(method, path, body=None):
        if path.endswith("/check-runs?per_page=100"):
            return {"check_runs": runs}
        if path.startswith("/commits/"):
            return {"commit": {"message": f"{subject}\n\nPromotion-Range: a..b\nPromotion-Kind: {kind}\n"}}
        raise AssertionError(path)
    return gh


def fake_prometheus(minutes=60, orders=1800, avail=0.0, latency=0.001, fired=(), firing=()):
    def prom(q):
        if q.startswith("count_over_time"):
            return [({}, minutes)] if minutes is not None else []
        if q.startswith("sum(increase"):
            return [({}, orders)]
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
        self.assertEqual(len(gates), 10)

    def test_paused(self):
        _, gates = evaluate(paused=True)
        self.assertEqual(failing(gates), ["automatic promotion not paused"])
        self.assertEqual(len(gates), 3, "cluster gates are skipped when a cheap gate fails")

    def test_feature_needs_the_owner(self):
        for kind in ("feature", "unknown"):
            _, gates = evaluate(gh=fake_github(kind=kind))
            self.assertEqual(failing(gates), ["ships only patches"])

    def test_missing_trailer_is_not_a_patch(self):
        gh = fake_github()
        _, gates = evaluate(gh=lambda m, p, b=None: {"commit": {"message": f"staging: orders-gateway {TAG}\n\nno trailers"}} if not p.endswith("per_page=100") else gh(m, p))
        self.assertEqual(failing(gates), ["ships only patches"])

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
        _, gates = evaluate(prom=fake_prometheus(orders=12))
        self.assertEqual(failing(gates), ["dev served at least 300 orders"])

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
