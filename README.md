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
| `promote.sh` | the four-step deploy: pull `:latest` onto the clone, check it, bump the live digest, verify both hostnames over real HTTPS |
| `drift-check.sh` | every manifest vs the live cluster, and vs git. Run it before trusting any measurement |
| `uptime-probe.sh` | **runs on jupiter, not in the cluster** — see below |

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

## Monitoring from outside the cluster

Everything else that watches this site runs **inside** it: Prometheus
scrapes it, Alertmanager pages from it. That stack cannot report the
failure that matters most, because the failure takes the reporter with
it. If the control plane goes, or MetalLB stops announcing the VIP, or
Traefik dies, the in-cluster alerting does not fire a warning — it goes
quiet, and quiet looks exactly like healthy.

`uptime-probe.sh` closes that. It runs on **jupiter** (192.168.100.114),
which is not a cluster node, from a user crontab every 5 minutes:

```
*/5 * * * * /home/mars/laravel-deploy/k8s/uptime-probe.sh >/dev/null 2>&1
```

It resolves the domains by public DNS and comes back in through the
router, so a pass exercises the whole real path — DNS, public IP, router,
MetalLB, Traefik, nginx, php-fpm, MySQL.

Four things worth knowing:

- **It asserts more than HTTP 200.** A maintenance page, a Laravel error
  page and a Basic-Auth prompt can all look fine to a status-code
  monitor; an overflow checker on this project already false-passed on a
  401 for exactly that reason. The probe requires that Inertia rendered
  `Home` *and* that each hostname served its own region, so `.ca`
  silently serving `com` listings is a failure too.
- **It tells "the site is down" apart from "my own internet is down"** by
  checking a third-party control URL before alerting. Without that it
  would cry wolf every time the house uplink blinked, which trains you to
  ignore it.
- **It alerts after 2 consecutive failures** (~10 minutes) and reminds
  hourly while still down, then sends an all-clear. A failed Discord
  send is *not* recorded as "notified", so an outage cannot be lost to a
  webhook hiccup.
- **A user crontab, deliberately, not a systemd user timer.** `linger` is
  off for this account, so user units stop at logout — monitoring that
  quietly stops when you log out is worse than none.

Config: webhook at `~/.config/basp-uptime/discord-webhook` (0600, read
from a file so it never appears in `ps`); state and log under
`~/.local/state/basp-uptime/`.

**The gap that remains:** jupiter shares a building, a power supply and an
uplink with the cluster. A failure of any of those is invisible to both,
and the symptom is silence again. Closing it needs a dead-man's switch on
a free external service (healthchecks.io) that alerts when heartbeats
*stop*. That needs an account, so it is left for a human — the hook is
written at the bottom of `uptime-probe.sh`.

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
