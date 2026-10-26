# What runs this site, and how the pieces touch each other

Written 2026-10-26, after two weeks of live operation in which every
listing photo returned 403 and was reported healthy. The point of this
document is that nobody should have to rediscover the system to answer
"what could this change break?"

Run **`./health-check.sh`** after every alteration. It is the executable
version of this document.

---

## The request path, end to end

```
visitor
  │  DNS: buyandsellpage.ca / .com  →  170.199.11.170
  ▼
router  →  MetalLB VIP 192.168.100.200
  ▼
Traefik (traefik-system)            ingress, TLS termination
  │   IngressRoute laravel-spa-https → service laravel-spa-app:80
  │   middlewares: redirect-to-https, redirect-www-to-apex
  ▼
nginx (in the app pod, port 8080)   static files, proxies PHP to fpm
  ▼
php-fpm 8.4.27                      the Laravel application
  ├──→ MySQL 8.4.11        192.168.100.111   OUTSIDE the cluster
  ├──→ Dragonfly           service "redis"   sessions db0 / cache db1
  └──→ SeaweedFS           service "minio"   object storage, S3 API
```

Photos do **not** travel that path. The browser fetches them directly:

```
<img src="https://cdn.buyandsellpage.ca/laravel-spa-uploads/...">
  ▼
Traefik  →  IngressRoute minio-public-https  →  service minio:9000
  ▼
SeaweedFS S3
```

**This is why the photo outage went unnoticed for two weeks.** The page
path and the image path share nothing but Traefik. Every check that
proved the page healthy told you nothing about images, because images
never touch the application at all.

---

## The programs

| Program | Version | Where | What it does | Breaks what if it stops |
|---|---|---|---|---|
| **Talos Linux** | v1.13.9 | 9 nodes | immutable OS; no shell, no SSH, no package manager, containerd not Docker | everything |
| **Kubernetes** | — | 3 control planes | schedules all of the below | everything |
| **Traefik** | chart 41.3.0 | traefik-system | ingress, TLS, redirect middlewares | the whole site AND images |
| **cert-manager** | v1.21.1 | cert-manager | Let's Encrypt via HTTP-01 | TLS expires in ~46 days |
| **MetalLB** | — | metallb-system | announces 192.168.100.200 by ARP | nothing reaches the cluster |
| **Longhorn** | v1.12.1 | longhorn-system | replicated block storage, 3 replicas | object storage volume |
| **PHP-FPM** | 8.4.27 | app pods | the application | the site |
| **nginx** | 1.30.4 | app pods | static files, FastCGI to php-fpm | the site |
| **MySQL** | 8.4.11 | .111, external | all data | the site |
| **Dragonfly** | df-v2.0.2 | laravel-spa | sessions + page cache (replaced Redis) | logins drop, pages slow |
| **SeaweedFS** | 4.48 | svc named `minio` | S3 object storage | **images only** |
| **Prometheus** | — | monitoring | metrics, 9 alert rules | alerting |
| **Alertmanager** | — | monitoring | routes alerts to Discord | you stop hearing |
| **Grafana** | — | 192.168.100.201:3000 | dashboards | visibility |
| **Sentry** | laravel 4.28 | in-app | application exceptions | error reports |

Outside the cluster:

| Host | What |
|---|---|
| **jupiter** .114 | workstation; holds kubeconfig, repos, the only offline copy of `k8s/secrets/`; runs the uptime probe and cert watcher from cron |
| **saturn** .110 | Mac on Ubuntu 26.04; **dev database** `basp_dev`, MySQL 8.4.11 |
| **.111** | production MySQL, no SSH, port 3306 only |
| **loadgen** .102 | Talos node, tainted, idle since capacity testing was retired |

---

## Names that lie

These have caught people out, including me.

- **The `minio` Deployment and Service run SeaweedFS**, not MinIO.
  MinIO's images stopped being anonymously pullable on 2026-10-13. The
  name stayed because `AWS_ENDPOINT` lives in a shared secret.
- **The `redis` Service routes to Dragonfly.** The Redis deployment is
  scaled to 0.
- **`ba-sp.com` is the dev tier**, not a test alias of the live site.
  `basp.com` (no hyphen) is **someone else's parked domain**.
- **Two headers**: `Header.vue` is the top bar; `SiteHeader.vue` is
  "header1".

---

## The three tiers, and what each shares

| | live | clone | dev |
|---|---|---|---|
| hostnames | buyandsellpage.ca/.com | www.foasfo.ca | ba-sp.com |
| image | pinned digest | `:latest` | `:latest` |
| database | `laravel` on .111 | **same as live** | `basp_dev` on saturn |
| cache | Dragonfly db 0/1 | Dragonfly db 2/3 | **own** dragonfly-dev |
| S3 bucket | laravel-spa-uploads | **same as live** | laravel-spa-dev-uploads |
| page cache | on | on | **off** |

The clone shares live's database **deliberately**, so an A/B comparison
measures the code change and not the environment. It is therefore NOT a
safe place to create test data.

All three run in the **same namespace** (`laravel-spa`), so isolation is
by configuration, not by boundary. A wrong `kubectl apply` can still
cross tiers.

---

## Interactions that are not obvious

**Publishing a listing invalidates three caches.** `HomeFeedInvalidator`
(via `#[ObservedBy]`) clears the per-subcategory feed; `CacheGuestPage`
clears the rendered page. Query-builder mass updates bypass Eloquent
events and therefore bypass both.

**The page cache key has no scheme.** An `http://` request to the app
service caches a render with `http://` asset URLs, which HTTPS visitors
then get as blocked mixed content. `URL::forceScheme('https')` defuses
it. This caused a real outage.

**SeaweedFS computes its volume budget at startup** as
`disk ÷ volumeSizeLimitMB`. Expanding the disk does nothing until it
restarts. Running out of volume *slots* stops uploads while the disk
looks empty.

**SeaweedFS grants public reads only through an identity named
`anonymous`.** Bucket policies do not apply. Without it every photo is
403 — which is what happened for two weeks.

**Pods reaching anything outside the cluster are SNAT'd to their node's
IP**, so external database grants must cover `192.168.100.%`, never a pod
address.

**`kubectl apply` never clears a field a manifest omits.** Values removed
from a file persist in the cluster. Writing `resources: {}` is what
actually removes limits.

**CI must pull base images.** `docker/build-push-action` defaults
`pull: false`; with a warm cache it will happily publish a months-old,
vulnerable PHP as a fresh build.

---

## What to run, and when

| When | Command |
|---|---|
| after **any** change | `./health-check.sh` |
| before trusting a measurement | `./drift-check.sh` |
| deploying | `./promote.sh --clone`, look, then `./promote.sh` |
| after a layout change | `npm run check:overflow` |
| after a code change | `./vendor/bin/phpunit` |
| cleaning up media | `php artisan storage:purge-orphans` |
