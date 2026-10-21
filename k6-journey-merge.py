#!/usr/bin/env python3
"""Merge the per-generator summaries of a journey run into one answer.

Twelve generators each print their own k6 summary, and the numbers in
them do not combine the same way:

  counts and rates  ADD exactly. Twelve generators doing 20 req/s each
                    are doing 240 req/s, full stop.
  percentiles       DO NOT. A p95 is a position in one generator's sample
                    set; averaging twelve of them is meaningless. What is
                    defensible is to treat the twelve as twelve estimates
                    of the same quantity and report the MEDIAN of them,
                    with the spread, which is what the p95 columns below
                    are. They are marked * for that reason.

Exact percentiles across all generators would need the raw samples --
k6's Prometheus remote-write output with native histograms would give
them, since histograms are additive. Deliberately not done yet: it needs
flags on Prometheus, and the knee is findable without it.
"""

import json
import pathlib
import re
import statistics
import sys


MARKER = "JOURNEY_SUMMARY_JSON "
# k6 writes its own messages as logfmt: time="..." level=info msg="..."
K6_LOG_RECORD = re.compile(r'time="\d{4}-\d{2}-\d{2}T[^\n]*')


def extract(text):
    """Pull the summary object out of one generator's log.

    THE CONTAINER RUNTIME SPLITS LOG LINES AT 16 KiB, and this summary is
    about 25 KB, so what k6 printed as one line can arrive as two or
    three. Whether it does depends on write buffering, so it hit one
    generator in twelve on the first real run and would have hit a
    different number next time -- the kind of defect that quietly drops a
    generator from the totals.

    Joining the lines back and decoding the first complete object fixes
    it: raw_decode stops at the end of the object and ignores whatever
    was printed after it (the wrapper's "k6 exit=0", for instance).
    """
    i = text.find(MARKER)
    if i < 0:
        return None
    # Excise k6's own logfmt records, then join what is left.
    #
    # Two things conspire here. The container runtime splits a log line at
    # 16 KiB and this summary is ~25 KB, so it can arrive in two pieces.
    # And k6 writes its own messages to the same stream, so one can land
    # between those pieces -- on the first real run a "thresholds have
    # been crossed" error was spliced in with NO newline before it, right
    # after `"max":60000.99`, so neither joining the lines nor dropping
    # whole lines recovered the JSON.
    #
    # A logfmt record starts with a timestamped `time="` and runs to the
    # end of its line, and the JSON itself never contains that, so
    # removing those spans is unambiguous.
    body = K6_LOG_RECORD.sub("", text[i + len(MARKER):])
    try:
        obj, _ = json.JSONDecoder().raw_decode(body.replace("\n", ""))
        return obj
    except json.JSONDecodeError as exc:
        print(f"  ! summary present but undecodable: {exc}", file=sys.stderr)
        return None


def load(directory):
    """Read every generator's summary out of the saved logs.

    The logs are the source of truth, not the extracted .json files: the
    extraction is what needed fixing, so it happens here where it can be
    fixed once.
    """
    root = pathlib.Path(directory)
    pods = {}
    logs = sorted((root / "logs").glob("*.log")) if (root / "logs").is_dir() else []
    for path in logs:
        obj = extract(path.read_text(errors="replace"))
        if obj is None:
            print(f"  ! {path.name}: no usable summary "
                  f"(generator died, or was terminated before printing)", file=sys.stderr)
            continue
        pods[path.stem] = obj
        # Keep the recovered object beside the log, so the run directory
        # stays self-describing without re-parsing a 1 MB log.
        (root / f"{path.stem}.json").write_text(json.dumps(obj))
    if pods:
        return pods
    # Older runs, collected before the logs were kept.
    for path in sorted(root.glob("*.json")):
        try:
            pods[path.stem] = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            print(f"  ! {path.name}: unparseable ({exc})", file=sys.stderr)
    return pods


def metric(pod, name, stair):
    return pod["metrics"].get(f"{name}{{stair:{stair}}}")


def total(pods, name, stair, key):
    out = 0.0
    seen = False
    for pod in pods.values():
        values = metric(pod, name, stair)
        if values and key in values:
            out += values[key]
            seen = True
    return out if seen else None


def spread(pods, name, stair, key):
    """The twelve estimates of one percentile: median, min, max, n."""
    samples = []
    for pod in pods.values():
        values = metric(pod, name, stair)
        if values and values.get("count") and key in values:
            samples.append(values[key])
    if not samples:
        return None
    return (statistics.median(samples), min(samples), max(samples), len(samples))


def ms(value):
    if value is None:
        return "-"
    if value >= 10000:
        return f"{value / 1000:.1f}s"
    if value >= 1000:
        return f"{value / 1000:.2f}s"
    return f"{value:.0f}ms"


STEPS = [
    ("home", "step_home"),
    ("listings_index", "step_listings_index"),
    ("listing_detail", "step_listing_detail"),
    ("search", "step_search"),
    ("subcategory", "step_subcategory"),
    ("login", "step_login"),
    ("save_ad", "step_save_ad"),
    ("contact_seller", "step_contact_seller"),
    ("post_form", "step_post_form"),
    ("publish_ad", "step_publish_ad"),
    ("post_yard_sale", "step_post_yard_sale"),
]


def main(directory):
    pods = load(directory)
    if not pods:
        print(f"No summaries found in {directory}", file=sys.stderr)
        return 1

    first = next(iter(pods.values()))
    labels = first["labels"]
    hold = first["hold_s"]
    generators = first["generators"]
    rates = {label: round(step * generators) for label, step in zip(labels, first["steps"])}

    print()
    print(f"Journey run on {first['host']} -- {len(pods)} of {generators} generator "
          f"summaries recovered")
    print(f"Each step held {hold:.0f}s after a {first['ramp_s']:.0f}s transition; "
          f"transitional samples are excluded (tagged 'ramp').")
    if len(pods) != generators:
        print(f"  ! {generators - len(pods)} summaries missing -- site-wide totals "
              f"below are UNDERSTATED by that fraction.")
    print()

    print("Offered load vs what came back")
    print(f"  {'step':<12} {'offered/s':>9} {'done/s':>8} {'sessions':>9} "
          f"{'reqs':>9} {'reqs/s':>8} {'fail%':>7} {'iter p95*':>10}")
    for label in labels:
        reqs = total(pods, "http_reqs", label, "count")
        passes = total(pods, "http_req_failed", label, "passes") or 0
        fails = total(pods, "http_req_failed", label, "fails") or 0
        checked = passes + fails
        iters = total(pods, "iteration_duration", label, "count") or 0
        iter_p95 = spread(pods, "iteration_duration", label, "p(95)")
        print(f"  {label:<12} {rates[label]:>9} {iters / hold:>8.1f} "
              f"{int(iters):>9} {int(reqs or 0):>9} {(reqs or 0) / hold:>8.1f} "
              f"{(100 * passes / checked if checked else 0):>7.2f} "
              f"{ms(iter_p95[0]) if iter_p95 else '-':>10}")
    print()
    print("  offered/s is the site-wide SESSION arrival rate the staircase asked")
    print("  for, and done/s is sessions actually finished during the hold --")
    print("  the two are the comparison that matters, and the knee is at the step")
    print("  where done/s stops tracking offered/s. reqs/s is a different unit:")
    print("  each session makes five or six requests, so it is roughly 5x done/s")
    print("  and is here only to size the traffic.")
    print()
    print("  Caveat on done/s and iter p95: a session is tagged with the step it")
    print("  ENDED in, and sessions last 20-60s against a 3m hold. So a step")
    print("  inherits some sessions that began in the one below it, which flatters")
    print("  a rising staircase slightly. Per-step LATENCIES below do not have")
    print("  this problem -- each request is tagged when it is made.")
    print()

    print("Latency per step, p95 (* median of the per-generator p95s)")
    header = f"  {'step':<16}" + "".join(f"{label:>12}" for label in labels)
    print(header)
    for name, key in STEPS:
        cells = []
        any_data = False
        for label in labels:
            got = spread(pods, key, label, "p(95)")
            if got:
                any_data = True
                cells.append(f"{ms(got[0]):>12}")
            else:
                cells.append(f"{'-':>12}")
        if any_data:
            print(f"  {name:<16}" + "".join(cells))
    print()

    print("Spread across generators, p95 of the home step (how much to trust *)")
    for label in labels:
        got = spread(pods, "step_home", label, "p(95)")
        if got:
            median, low, high, n = got
            print(f"  {label:<12} median {ms(median):>8}   range {ms(low)} - {ms(high)}"
                  f"   from {n} generators")
    print()

    print("Medians per step (p50 is where the typical visitor sits)")
    header = f"  {'step':<16}" + "".join(f"{label:>12}" for label in labels)
    print(header)
    for name, key in STEPS:
        cells = []
        any_data = False
        for label in labels:
            got = spread(pods, key, label, "med")
            if got:
                any_data = True
                cells.append(f"{ms(got[0]):>12}")
            else:
                cells.append(f"{'-':>12}")
        if any_data:
            print(f"  {name:<16}" + "".join(cells))
    print()

    # Run-wide figures that carry no stair tag, so they can only be read
    # as totals: dropped iterations are k6 giving up on scheduled work,
    # which is the clearest single sign the offered rate was not met.
    dropped = sum(pod["metrics"].get("dropped_iterations", {}).get("count", 0)
                  for pod in pods.values())
    vus_max = sum(pod["metrics"].get("vus_max", {}).get("max", 0) for pod in pods.values())
    print(f"Whole run: {int(dropped)} dropped iterations, {int(vus_max)} VUs "
          f"pre-allocated across generators (untagged, so run-wide only)")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
