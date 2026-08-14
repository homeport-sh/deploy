#!/usr/bin/env bash
#
# Ship a binary to a homeport box.
#
# The whole point of this script is what it does not need: there is no key, no
# password, and no `secrets:` block in the workflow that calls it. GitHub mints
# a token for this run, we prove the run's identity with it once, and it
# expires in minutes whether or not anything goes wrong.
#
# Four steps, matching the API:
#   1. ask GitHub for an OIDC token for our audience
#   2. open a deployment  → upload URL + completion token
#   3. PUT the binary straight to object storage
#   4. complete, then wait for the box's answer
set -euo pipefail

# Tokens are passed to curl through stdin config files rather than argv, so
# they never appear in a process listing. Runners are ephemeral, but the habit
# is cheap and the alternative is a leak nobody notices.
die() { printf '::error::%s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

for tool in curl jq; do
  command -v "$tool" >/dev/null || die "$tool is required but not installed"
done

: "${HOMEPORT_APP:?app is required}"
: "${HOMEPORT_ARTIFACT:?artifact is required}"
: "${HOMEPORT_API:?api-url is required}"
: "${HOMEPORT_AUDIENCE:?audience is required}"
: "${HOMEPORT_TIMEOUT:=600}"

API="${HOMEPORT_API%/}"

[[ -f $HOMEPORT_ARTIFACT ]] || die "no artifact at $HOMEPORT_ARTIFACT — did the build step run?"
[[ -s $HOMEPORT_ARTIFACT ]] || die "$HOMEPORT_ARTIFACT is empty"

# A macOS or Windows binary uploads perfectly well and is refused on arrival.
# Saying so here costs one line and saves reading an HTTP 422.
if ! head -c 4 "$HOMEPORT_ARTIFACT" | grep -q $'\x7fELF'; then
  die "$HOMEPORT_ARTIFACT is not a Linux (ELF) executable — check the build's GOOS/target"
fi

# ---------------------------------------------------------------- 1. identity

[[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} && -n ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-} ]] || die \
  "no OIDC token available — the job needs 'permissions: id-token: write'"

request_token() {
  printf 'header = "Authorization: Bearer %s"\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN"
  printf 'url = "%s&audience=%s"\n' "$ACTIONS_ID_TOKEN_REQUEST_URL" "$HOMEPORT_AUDIENCE"
}

oidc_response=$(request_token | curl --silent --show-error --fail-with-body --config -) ||
  die "could not get an OIDC token from GitHub"
OIDC_TOKEN=$(printf '%s' "$oidc_response" | jq -r '.value // empty')
[[ -n $OIDC_TOKEN ]] || die "GitHub returned no OIDC token"

# ------------------------------------------------------------ 2. open a deploy

api_call() { # <token> <method> <path> [json body]
  local token=$1 method=$2 path=$3 body=${4:-}
  {
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    printf 'header = "Content-Type: application/json"\n'
    printf 'request = "%s"\n' "$method"
    printf 'url = "%s%s"\n' "$API" "$path"
    printf 'write-out = "\\n%%{http_code}"\n'
    [[ -n $body ]] && printf 'data = "%s"\n' "${body//\"/\\\"}"
    printf 'silent\nshow-error\n'
  } | curl --config -
}

# split_status separates the trailing status code curl writes out.
status_of() { printf '%s' "$1" | tail -n1; }
body_of() { printf '%s' "$1" | sed '$d'; }

explain() { # <body> — the API's public reason, or the raw body
  printf '%s' "$1" | jq -r '.error // empty' 2>/dev/null || printf '%s' "$1"
}

note "Opening a deployment for ${HOMEPORT_APP}…"
response=$(api_call "$OIDC_TOKEN" POST /v1/deployments "$(jq -nc --arg app "$HOMEPORT_APP" '{app:$app}')")
code=$(status_of "$response")
payload=$(body_of "$response")

case $code in
  201) ;;
  401) die "the API rejected this run's token: $(explain "$payload")" ;;
  403) die "this repository is not authorised to deploy '${HOMEPORT_APP}' — check the app and the branch" ;;
  409) die "the box is not ready: $(explain "$payload")" ;;
  *)   die "opening the deployment failed (HTTP $code): $(explain "$payload")" ;;
esac

DEPLOYMENT_ID=$(printf '%s' "$payload" | jq -r '.deployment_id')
UPLOAD_URL=$(printf '%s' "$payload" | jq -r '.upload_url')
COMPLETION_TOKEN=$(printf '%s' "$payload" | jq -r '.completion_token')
[[ -n $DEPLOYMENT_ID && -n $UPLOAD_URL && -n $COMPLETION_TOKEN ]] ||
  die "the API's response was incomplete"

note "Deployment ${DEPLOYMENT_ID}"
printf 'deployment-id=%s\n' "$DEPLOYMENT_ID" >>"${GITHUB_OUTPUT:-/dev/null}"

# ------------------------------------------------------------------ 3. upload

# Straight to object storage. The bytes never pass through the control plane,
# and the URL is good for this one object until it expires.
note "Uploading $(du -h "$HOMEPORT_ARTIFACT" | cut -f1)…"
upload_code=$(curl --silent --show-error --request PUT \
  --upload-file "$HOMEPORT_ARTIFACT" \
  --write-out '%{http_code}' --output /dev/null \
  "$UPLOAD_URL") || die "the upload failed"
[[ $upload_code -ge 200 && $upload_code -lt 300 ]] ||
  die "the object store refused the upload (HTTP $upload_code)"

# ---------------------------------------------------------------- 4. complete

note "Validating…"
response=$(api_call "$COMPLETION_TOKEN" POST "/v1/deployments/${DEPLOYMENT_ID}/complete")
code=$(status_of "$response")
payload=$(body_of "$response")

case $code in
  200) ;;
  400) die "no artifact arrived — the upload did not land: $(explain "$payload")" ;;
  413) die "the artifact is too large: $(explain "$payload")" ;;
  422) die "the artifact was rejected: $(explain "$payload")" ;;
  *)   die "completing the deployment failed (HTTP $code): $(explain "$payload")" ;;
esac
note "Accepted: $(printf '%s' "$payload" | jq -r '"\(.arch), \(.bytes) bytes"')"

# ---------------------------------------------------------------- 5. the wait
#
# Reporting success at the upload would be a lie: the deploy has not happened
# yet. Wait for the box's own answer, and fail with whatever it said.

note "Waiting for the release…"
deadline=$(( $(date +%s) + HOMEPORT_TIMEOUT ))
status=uploaded

while (( $(date +%s) < deadline )); do
  sleep 3
  response=$(api_call "$COMPLETION_TOKEN" GET "/v1/deployments/${DEPLOYMENT_ID}")
  code=$(status_of "$response")
  payload=$(body_of "$response")
  [[ $code == 200 ]] || continue   # a transient blip is not a failed deploy

  status=$(printf '%s' "$payload" | jq -r '.status')
  case $status in
    live)
      printf 'status=live\n' >>"${GITHUB_OUTPUT:-/dev/null}"
      note "Deployed. ${HOMEPORT_APP} is live."
      exit 0
      ;;
    failed)
      printf 'status=failed\n' >>"${GITHUB_OUTPUT:-/dev/null}"
      die "the deploy failed: $(printf '%s' "$payload" | jq -r '.detail // "no reason given"')"
      ;;
  esac
done

printf 'status=%s\n' "$status" >>"${GITHUB_OUTPUT:-/dev/null}"
die "gave up waiting after ${HOMEPORT_TIMEOUT}s; the deployment is still ${status}. It may yet land — check ${DEPLOYMENT_ID}."
