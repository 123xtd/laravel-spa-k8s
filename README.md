# Buy and Sell Page — Kubernetes manifests

Infrastructure for the Talos cluster that runs
[laravel-spa](https://github.com/123xtd/laravel-spa). Applied manually
with `kubectl apply`; there is no CI for this directory.

Put under version control 2026-10-13, after a day of capacity work left
roughly 3,500 lines of unreproducible infrastructure sitting on one
disk — the clone, the A/B routing, the monitoring stack, the SeaweedFS
migration and the journey load test.

## Credentials

No credential is committed. Every manifest reaches them through
`secretKeyRef`, so this repo fully describes the configuration while
containing none of the values. See [secrets/README.md](secrets/README.md)
and `app-secrets.example.yaml`.

## The cluster

8 nodes, Talos Linux, 3 control planes, 84 CPUs. Flat `192.168.100.0/24`.
MySQL is **outside** the cluster at `192.168.100.111` with only port 3306
reachable — no SSH, no metrics exporter, so its host CPU cannot be seen
from here.

| | |
|---|---|
| Ingress | Traefik, MetalLB pool `192.168.100.200-210` |
| Storage | Longhorn; SeaweedFS for S3 |
| Monitoring | Prometheus + Grafana at `192.168.100.201:3000` |

## What's here

| File | |
|---|---|
| `app-deployment.yaml` | the real site (`foasfo.ca`) — **image pinned to a digest**, see below |
| `app-clone.yaml` | the A/B variant (`www.foasfo.ca`) |
| `test-domains.yaml` | Traefik routing, TLS, basic-auth wall |
| `seaweedfs.yaml` | S3 object store (replaced MinIO) |
| `redis.yaml` | sessions, cache, queues |
| `monitoring/` | Prometheus, Grafana, node/redis/mysqld exporters |
| `k6-journey-job.yaml` | journey load test — personas, per-activity costs |
| `k6-lb-job.yaml` | the older brute-force ramp, kept as the comparable baseline |
| `database-backup-cronjob.yaml`, `yard-sales-prune-cronjob.yaml` | scheduled work |

## Two things that will surprise you

**The real site's image is pinned to a digest, not `:latest`.** It is the
control side of a running A/B, and a digest cannot drift when CI
publishes variant code. A deploy of the real site therefore needs the
digest updated deliberately — `:latest` will not pick anything up.

**The Service named `minio` now fronts SeaweedFS.** MinIO's container
images stopped being anonymously pullable (verified: every tag, both
registries). The name stays because `AWS_ENDPOINT` lives in the shared
`laravel-spa-secrets` that both app tiers read. Rename it once the A/B is
done.

## Applying from scratch

```bash
kubectl apply -f secrets/            # credentials first
kubectl apply -f app-secrets.yaml
kubectl apply -f redis.yaml -f seaweedfs.yaml
kubectl apply -f app-deployment.yaml -f test-domains.yaml
kubectl apply -f monitoring/         # in filename order
```

Migrations are never run automatically. After a deploy that includes
them: `kubectl exec deploy/laravel-spa-app -- php artisan migrate --force`.
