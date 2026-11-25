# 0021: Trivy Operator in the cluster, trimmed to fit the budget

**Status:** Accepted, 2026-11-25

## Context

The brief's architecture table (section 4) fixes image scanning as "Trivy in CI + Trivy Operator in cluster". Section 9 says the Operator "continuously scans running images and cluster configuration, exports metrics to Prometheus and feeds the security dashboard", trimmed to fit the budget. CI scans only the app image, at build time (decision 0016) and daily (decision 0019). Nothing scanned the third-party images the cluster runs, or the workloads' configuration.

## Choices

- **Chart `trivy-operator` 0.38.1 (operator v0.36.1)**, wave 20, namespace `trivy-system`, Pod Security `restricted` enforced. The operator, the server and the scan Jobs all run non-root, with RuntimeDefault seccomp, no privilege escalation, all capabilities dropped, and a read-only root filesystem.
- **Scanners on:**
  - vulnerabilities in every running workload's images;
  - configuration audit of the workloads.
- **Scanners off, to save CPU and memory:**
  - RBAC and infra (node) assessments;
  - cluster compliance reports;
  - secrets baked into images;
  - SBOM reports (the app's SBOM is in its image index, decision 0013).
- **One shared Trivy server** (`builtInTrivyServer`, ClientServer mode) holds the vulnerability DB on an emptyDir. Scan Jobs are clients and don't load the DB. `scanJobsConcurrentLimit: 1`. Scan Jobs: 50m / 128Mi requested, 512Mi limit.
- **Images from Docker Hub**, which is an approved registry in `restrict-image-registries`, instead of the chart's default `mirror.gcr.io`. The node collector isn't used, since infra assessment is off.
- **Metrics:** a ServiceMonitor scrapes `trivy_image_vulnerabilities{namespace, resource_name, image_repository, image_tag, severity}` and `trivy_resource_configaudits`. A NetworkPolicy for `trivy-system` follows decision 0017: same-namespace (scan Jobs → server), nodes, and Prometheus on port 8080.

## Measured on ogp (installed by hand, then removed)

- Within a few minutes: 33 VulnerabilityReports and 122 ConfigAuditReports, with no Pod Security rejections.
- `./platform budget --watch 120` while it scanned: peak 2.97 of 6 CPU and 7365 of 12288 MiB (59%), no OOM kills.
- `trivy-system` used about 275 MiB: the operator about 220Mi (so its limit is 384Mi), the server about 56Mi.

## Consequences

- The security dashboard and an alert on fixable HIGH/CRITICAL in running images come in a follow-up, built on these metrics.
- The rescan workflow (decision 0019) stays. It covers the app image even when no cluster is running.
