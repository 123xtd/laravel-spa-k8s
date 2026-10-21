#!/usr/bin/env bash
#
# Post-install setup for `loadgen` (192.168.100.102), the dedicated load
# generator box.
#
# WHY THIS FILE EXISTS
#
# Everything else about this node lives in its Talos machine config
# (/home/mars/talos-configs/worker-loadgen.yaml) and survives a rebuild:
# the static address, the install disk, the hostname, the
# workload=loadtest label.
#
# The taint cannot. Kubernetes' NodeRestriction admission plugin forbids
# a node from modifying taints on its own Node object, so Talos gets
# `nodes "loadgen" is forbidden: node "loadgen" is not allowed to modify
# taints` and -- because it applies labels and taints as one patch --
# the label silently fails along with it. The taint therefore has to be
# applied from the control plane, which means from here.
#
# RUN THIS AFTER ANY REINSTALL OF loadgen. Without the taint the node is
# just an ordinary worker with spare capacity, so the scheduler will put
# app pods on it -- and the next HPA scale-up to 40 replicas certainly
# will. At that point the generator is competing with the system it is
# measuring, which is the exact problem this box was bought to solve.
#
# Idempotent: re-running it changes nothing.

set -euo pipefail

NODE=loadgen
TAINT=dedicated=loadtest:NoSchedule

echo "==> tainting ${NODE} with ${TAINT}"
kubectl taint node "${NODE}" "${TAINT}" --overwrite

# Anything that was scheduled before the taint existed keeps running:
# NoSchedule governs placement, not eviction. These have to be removed by
# hand once, and the DaemonSet controllers will not put them back.
#
# Deliberately NOT removed:
#   kube-flannel, kube-proxy  -- cluster networking; the generators need
#                                it to reach the service at all, and both
#                                tolerate every taint by design.
#   node-exporter             -- WANTED. It is how the generator box's own
#                                CPU, memory and NIC are read during a
#                                run, which is how we tell "the site
#                                saturated" from "the rig saturated".
echo "==> removing storage pods that predate the taint"
kubectl delete pod -n longhorn-system \
  --field-selector "spec.nodeName=${NODE}" --ignore-not-found

# Longhorn would otherwise offer this box's 248GB EPHEMERAL partition as
# cluster storage, which means a volume replica could land on the machine
# that is about to be driven to 100% CPU and 100% NIC for twenty minutes.
echo "==> marking the node unschedulable for Longhorn storage"
kubectl label node "${NODE}" node.longhorn.io/create-default-disk=false --overwrite

echo
echo "==> result"
kubectl get node "${NODE}" \
  -o custom-columns='NAME:.metadata.name,LABEL:.metadata.labels.workload,TAINTS:.spec.taints[*].key'
echo
kubectl get pods -A --field-selector "spec.nodeName=${NODE}" \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase'
