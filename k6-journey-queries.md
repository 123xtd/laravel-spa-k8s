# Watching a journey run live

## Getting there

**http://192.168.100.201:3000** -> sign in as `admin` -> hamburger menu
(top left) -> **Dashboards** -> **Load test: journey run**.

Direct link: http://192.168.100.201:3000/d/journey/load-test3a-journey-run

The password (the secret's keys are `username` and `password`, not the
`admin-*` names Grafana's own env vars use):

    kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.password}' | base64 -d

The dashboard covers the run. The queries below are for Explore, when you
want something it does not show.

Prometheus itself stays ClusterIP on purpose: `--web.enable-remote-write-receiver`
means `/api/v1/write` accepts anything that can reach it, so it is not
given a LAN address. Grafana has a login and already has it as a
datasource.

The generators push every 5 seconds, so everything below updates during
the run -- and survives a generator being killed, which is the whole
point of streaming it out.

## Labels you can group by

| label | values |
|---|---|
| `stair` | `s1_48`, `s2_90`, `s3_132`, `s4_174`, `s5_216`, `s6_258`, `s7_300`, plus `ramp` (transitions, excluded from steps) and `tail` (write personas outliving the staircase) |
| `gen` | one per generator pod -- **leave it out to get the site-wide figure** |
| `scenario` | `scroller`, `searcher`, `checker`, `saver`, `enquirer`, `poster`, `yardsaler` |

## The queries that answer the question

**Site-wide p95 of the home page, per staircase step.** This is the knee.
The twelve generators are native histograms, so summing them and then
taking the quantile is the real figure, not an average of twelve
estimates:

    histogram_quantile(0.95, sum by (stair) (rate(k6_step_home_seconds[1m])))

**Every step at once, as a curve over time:**

    histogram_quantile(0.95, sum by (__name__) (rate({__name__=~"k6_step_.*_seconds"}[1m])))

**Sessions actually completed per second** -- compare against the step's
offered rate (48/90/132/174/216/258/300). Where this stops tracking, the
site or the rig has stopped keeping up:

    sum(rate(k6_iterations_total[1m]))

**Dropped iterations** -- k6 giving up on scheduled work. Rising means the
offered rate is not being met, and above 216/sec expect this to be the
generators running out of memory rather than the site refusing:

    sum(rate(k6_dropped_iterations_total[1m]))

**Failure rate:**

    sum(rate(k6_http_req_failed_rate[1m])) / sum(rate(k6_http_reqs_total[1m]))

**Generator health -- read this before believing anything above 216/sec:**

    # generator memory in GB -- the box has ~13.5 GB usable
    sum(container_memory_working_set_bytes{namespace="laravel-spa",pod=~"k6-journey.*"}) / 1024^3
    # how many generators are still alive and reporting (should be 12)
    count(count by (gen) (k6_vus))

**Is it the site or the rig?** The honest test: if latency rises while
generator memory is climbing towards 13 GB, it is the rig. If latency
rises while generator memory is flat, it is the site.

## The site's own side

    # app pods, and whether the HPA is even reacting
    kube_horizontalpodautoscaler_status_current_replicas{namespace="laravel-spa"}
    sum(rate(container_cpu_usage_seconds_total{namespace="laravel-spa",pod=~"laravel-spa-app-clone.*"}[1m]))

Note the 2026-10-15 finding: the app HPA scales on CPU and is structurally
blind to an I/O stall, so `home` p95 reached 10.79s while the HPA sat at
24 replicas with an idle fleet. Watch latency, not replica count.
