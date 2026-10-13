# Cluster monitoring

Prometheus + Grafana, built 2026-10-13. Apply in filename order.

**Grafana: http://192.168.100.201:3000** — credentials are in the
`grafana-admin` Secret:

```bash
kubectl get secret grafana-admin -n monitoring \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Start at the **Capacity & Bottlenecks** dashboard. Its panels are in the
order the capacity investigation actually needed them.

## Why this exists

A capacity investigation on 2026-10-12/13 took hours partly because
nothing here existed. Two of the three bottlenecks found were **cgroup
CPU throttling** — Redis capped at `250m` and frozen 22% of wall clock,
then the app tier capped at 2 cores per pod and freezing 100% of periods
on its hottest pods.

Throttling is invisible in `kubectl top`: a throttled container reports
*low* CPU usage while being completely stalled. So the cluster looked 95%
idle while the site collapsed, and every obvious suspect (app CPU,
memory, network, disk, MySQL connections) was eliminated in turn before
the real cause surfaced. The metric that shows it,
`container_cpu_cfs_throttled_periods_total`, is the first panel on the
dashboard.

`metrics-server` was already installed and is **not** a substitute: it
keeps a ~15 second rolling window with no history, and knows nothing
about MySQL, Redis, Traefik, or throttling.

## What's collected

| Source | How | Gives you |
|---|---|---|
| cAdvisor | API-server proxy, all 8 nodes | per-container CPU, memory, **throttling**, limits |
| kubelet | API-server proxy | node and volume stats |
| node-exporter | DaemonSet, all 8 nodes | host CPU per core, memory, **swap**, disk, network |
| Traefik | already exposed on `:9100` | request rate, p95 latency, status codes |
| redis-exporter | Deployment | ops/sec, connected clients, hit ratio, blocked clients |
| mysqld-exporter | Deployment → `192.168.100.111:3306` | queries/sec, **rows read/sec**, connections, InnoDB state |

Exporters are discovered by the `kubernetes-pods` scrape job via
`prometheus.io/scrape` annotations, so adding another one needs no
change to the Prometheus config.

Retention is 15 days at a 15s scrape interval, on a 10Gi Longhorn PVC.

## Two gaps to be aware of

1. **The database host's CPU cannot be seen from here.** `.111` is
   outside the cluster with only 3306 reachable — no SSH, no
   node-exporter. mysqld-exporter reports what MySQL knows about
   *itself*, not the machine's load average, per-core usage or swap.
   Those still have to be read off a screen on the box. Closing this
   needs node-exporter installed on `.111` directly.
2. **Prometheus is a single replica with no alerting.** It records
   history so you can look back, but nothing will tell you unprompted.
   Alertmanager is the obvious next addition.

## Setup notes worth keeping

- **Talos enforces PodSecurity `baseline` cluster-wide by default**, and
  that default does **not** appear in a namespace's own labels — an
  unlabelled namespace looks unrestricted but is not. node-exporter
  needs hostNetwork/hostPID/hostPath/hostPort, all of which `baseline`
  forbids, so the `monitoring` namespace carries
  `pod-security.kubernetes.io/enforce: privileged`, the same way
  `longhorn-system` and `metallb-system` do.
- **node-exporter listens on 9101, not the usual 9100** — Traefik's
  metrics entrypoint already holds 9100, and `hostNetwork: true` means
  they share the node's port space.
- **Neither Prometheus nor node-exporter has a CPU limit**, deliberately.
  Throttling a monitoring pod loses visibility exactly when load is
  highest, which is the whole lesson here. Memory is capped because that
  protects the node; CPU is compressible and does not need to be.
- **Both PVC-backed deployments use `strategy: Recreate`.** The volumes
  are ReadWriteOnce, so a rolling update would deadlock waiting for a
  volume the old pod still holds.
- Grafana's dashboards mount at `/etc/grafana/dashboards`, deliberately
  not under `/var/lib/grafana` — that path is the PVC mount, and nesting
  a ConfigMap inside it can shadow the volume.

## Querying directly, without Grafana

```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# then http://localhost:9090
```

Throttling as a percentage, which is the query worth remembering:

```promql
sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{container!=""}[5m]))
  / clamp_min(sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{container!=""}[5m])), 1)
```

Anything sustained above ~5% is costing latency. Above ~20% it is
probably the bottleneck.

## Note on this directory

`~/laravel-deploy/k8s` is not under version control, so these manifests
exist only on jupiter. Worth fixing at some point.
