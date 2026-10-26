#!/usr/bin/env bash
#
# Adds an `anonymous` read identity to SeaweedFS so listing photos load
# for visitors, and restarts it so the change (and the expanded disk)
# takes effect.
#
# WHY THIS IS NEEDED
#
# Every listing photo on the live site has returned 403 AccessDenied to
# visitors since the MinIO -> SeaweedFS migration on 2026-10-13. Confirmed
# in a real browser: both listings' thumbnails fail with naturalWidth 0.
#
# MinIO served public objects through a bucket policy. SeaweedFS does not
# read bucket policies for this -- it grants unauthenticated access only
# through an identity literally NAMED `anonymous`. s3.json has only the
# credentialed `laravel-spa` identity, so every public GET is denied.
#
# WHAT IT GRANTS, AND WHAT IT DELIBERATELY DOES NOT
#
#   Read:laravel-spa-uploads   <- photos become publicly readable
#
# Not `Read` unscoped, which would expose laravel-spa-backups -- the
# database dumps. Not `List`, because the bucket index is nobody's
# business: without it a stranger can fetch a photo whose exact key they
# already know, which is what a page needs, and cannot enumerate the rest.
#
# The existing credentialed identity is preserved untouched. The secret is
# read and rewritten in place; no credential is ever printed.

set -euo pipefail

NS=laravel-spa
SECRET=seaweedfs-s3-config
BUCKET=laravel-spa-uploads
DEPLOY=minio   # the deployment is still called minio; it runs seaweedfs

TMP="$(mktemp -d)"; chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "== reading the current s3.json"
kubectl get secret "$SECRET" -n "$NS" -o jsonpath='{.data.s3\.json}' | base64 -d > "$TMP/s3.json"
echo "   $(wc -c < "$TMP/s3.json") bytes, $(python3 -c "
import json;print(len(json.load(open('$TMP/s3.json')).get('identities',[])))
") identity(ies)"

echo "== adding the anonymous identity"
python3 - "$TMP/s3.json" "$BUCKET" <<'PY'
import json, sys
path, bucket = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
ids = cfg.setdefault('identities', [])

if any(i.get('name') == 'anonymous' for i in ids):
    print('   already present, leaving it alone')
    sys.exit(0)

# Appended, not inserted: SeaweedFS matches the credentialed identity by
# access key, so order does not affect authenticated requests.
ids.append({
    'name': 'anonymous',
    'actions': [f'Read:{bucket}'],
})
json.dump(cfg, open(path, 'w'), indent=2)
print(f'   added: anonymous with Read:{bucket}')
PY

echo "== applying"
kubectl create secret generic "$SECRET" -n "$NS" \
  --from-file=s3.json="$TMP/s3.json" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "   secret/$SECRET updated"

echo "== restarting seaweedfs"
echo "   this also makes it recalculate its volume budget from the"
echo "   expanded disk -- it computes disk/volumeSizeLimitMB at STARTUP,"
echo "   so the 20Gi->60Gi expansion has had no effect until now."
kubectl rollout restart "deployment/$DEPLOY" -n "$NS" >/dev/null
kubectl rollout status "deployment/$DEPLOY" -n "$NS" --timeout=300s | sed 's/^/   /'
