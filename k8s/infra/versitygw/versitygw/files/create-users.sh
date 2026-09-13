#!/bin/sh
# Reconciles every versitygw account this chart manages, sequentially.
#
# Deliberately ONE process for ALL accounts. versitygw's S3 IAM backend has
# no cross-write locking on users.json (see BOOTSTRAP.md) -- running one Job
# per client raced in production: each Job's own PATCH genuinely returned
# 201, but a later concurrent write from another Job (landing on a different
# versitygw replica) read a stale users.json and overwrote it, silently
# dropping earlier accounts. sonarr and prowlarr both vanished that way
# despite their own Jobs logging success.
#
# Inputs (all from the environment):
#   ADMIN, S3, SIGV4            versitygw endpoints and sigv4 scope
#   ROOT_ACCESS_KEY_ID/SECRET   root credentials
#   CLIENTS                     one "<id> <bucket>" per line
#   <ID>_ACCESS_KEY_ID/SECRET   per-client credentials, id upper-cased with
#                               '-' mapped to '_' (see varprefix below)
set -eu

# On a FRESH cluster these Jobs are scheduled alongside versitygw itself and
# lose the race -- measured: job pods started at 12:06:26, the gateway at
# 12:06:31. With `set -e`, `code=$(curl ...)` makes any transport error fatal
# on the spot ("curl: (52) Empty reply from server"), so the Job burned its
# backoffLimit before the gateway was listening. Two of these guards:
#
#   1. retry flags cover transport errors (52, connection refused, resets).
#      Safe to use --retry-all-errors ONLY because we never pass -f/--fail:
#      an HTTP 409 is exit 0 to curl, so real HTTP statuses are still handled
#      by the case statements below rather than silently retried.
#   2. wait_for_gateway blocks until the S3 endpoint answers at all.
CURL_RETRY="--retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors"

wait_for_gateway() {
  i=1
  while [ "$i" -le 60 ]; do
    # Any HTTP response means it is listening; we do not care which, since
    # this is unauthenticated and will be a 403 or similar.
    if curl -sS -o /dev/null --max-time 5 "$S3/" 2>/dev/null; then
      echo "versitygw is responding"
      return 0
    fi
    echo "waiting for versitygw ($i/60)"
    i=$((i + 1))
    sleep 5
  done
  echo "versitygw did not become ready in 5 minutes"
  exit 1
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

# Client ids contain hyphens (forgejo-data), which are not legal in env var
# names -- the Helm side maps them to underscores, so this must too.
varprefix() {
  echo "$1" | tr '[:lower:]-' '[:upper:]_'
}

client_access() { eval "printf '%s' \"\$$(varprefix "$1")_ACCESS_KEY_ID\""; }
client_secret() { eval "printf '%s' \"\$$(varprefix "$1")_SECRET_ACCESS_KEY\""; }

# Reconciles the account to whatever the generated Secret currently holds --
# it does not merely assert that an account by that name exists.
#
# An earlier version treated 409 as success, which made this a no-op in
# exactly the case where reconciliation is needed. If versitygw's stored
# secret ever diverged from the generated Secret the drift was permanent and
# invisible: the Job kept going Complete while the client got
# SignatureDoesNotMatch on every request.
reconcile_user() {
  id=$1
  access=$(client_access "$id")
  secret=$(client_secret "$id")
  escaped_access=$(xml_escape "$access")
  escaped_secret=$(xml_escape "$secret")

  body="<Account><Access>${escaped_access}</Access><Secret>${escaped_secret}</Secret><Role>user</Role></Account>"
  code=$(curl -sS $CURL_RETRY -o /tmp/resp.xml -w '%{http_code}' \
    --aws-sigv4 "$SIGV4" \
    --user "${ROOT_ACCESS_KEY_ID}:${ROOT_SECRET_ACCESS_KEY}" \
    -X PATCH "$ADMIN/create-user" \
    -H 'Content-Type: application/xml' \
    --data-binary "$body")
  echo "$id create-user -> HTTP $code"; cat /tmp/resp.xml; echo

  case "$code" in
    201)
      echo "$id: account created"
      ;;
    409)
      # Account exists; create-user will not touch its secret, so write the
      # current one explicitly. Access keys are alphanumeric + hyphen, so no
      # query-string escaping is needed here.
      body="<MutableProps><Secret>${escaped_secret}</Secret></MutableProps>"
      code=$(curl -sS $CURL_RETRY -o /tmp/resp.xml -w '%{http_code}' \
        --aws-sigv4 "$SIGV4" \
        --user "${ROOT_ACCESS_KEY_ID}:${ROOT_SECRET_ACCESS_KEY}" \
        -X PATCH "$ADMIN/update-user?access=${access}" \
        -H 'Content-Type: application/xml' \
        --data-binary "$body")
      echo "$id update-user -> HTTP $code"; cat /tmp/resp.xml; echo
      case "$code" in
        200|204) echo "$id: account secret reconciled" ;;
        *) echo "$id: update-user failed"; exit 1 ;;
      esac
      ;;
    *)
      echo "$id: create-user failed"; exit 1
      ;;
  esac
}

# Proves the credential this chart just wrote actually authenticates, using
# the CLIENT's own key rather than root. Without this the Job can go Complete
# while the account is unusable -- the state seerr sat in for five days.
#
# Deliberately tolerant of authZ, strict about authN: bucket policies are
# applied by SEPARATE Jobs with no ordering guarantee relative to this one,
# so an AccessDenied here just means the policy has not landed yet and is not
# a failure. A signature or key-id rejection is different in kind -- it means
# versitygw's stored secret does not match what we hold, which is the whole
# bug class this guards.
verify_user() {
  id=$1
  bucket=$2
  access=$(client_access "$id")
  secret=$(client_secret "$id")

  code=$(curl -sS $CURL_RETRY -o /tmp/verify.xml -w '%{http_code}' \
    --aws-sigv4 "$SIGV4" \
    --user "${access}:${secret}" \
    "$S3/${bucket}?list-type=2&max-keys=1")
  echo "$id verify (ListBucket $bucket as $access) -> HTTP $code"

  if [ "$code" = "200" ]; then
    echo "$id: credential verified"
    return 0
  fi
  if grep -q 'SignatureDoesNotMatch\|InvalidAccessKeyId' /tmp/verify.xml; then
    echo "$id: CREDENTIAL MISMATCH -- versitygw's stored secret does not"
    echo "  match ${id}-versitygw-generated."
    cat /tmp/verify.xml; echo
    return 1
  fi
  echo "$id: authenticated; not yet authorized (bucket policy or bucket"
  echo "  still pending) -- OK"
  return 0
}

# Fed by here-doc rather than a pipe so the loop runs in THIS shell: a
# pipeline would put it in a subshell and "failed" would be lost, turning
# every verification failure into a silent pass.
wait_for_gateway

failed=""
while IFS=' ' read -r id bucket; do
  [ -n "$id" ] || continue
  reconcile_user "$id"
  verify_user "$id" "$bucket" || failed="$failed $id"
done <<EOF
$CLIENTS
EOF

# Verify every client before failing, so one broken account does not mask the
# state of the others in the Job log. (A create- or update-user error is
# different: that exits immediately, since it means the admin API itself is
# not behaving.)
if [ -n "$failed" ]; then
  echo "FAILED verification for:$failed"
  exit 1
fi
echo "all clients reconciled and verified"
