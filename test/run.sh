#!/usr/bin/env bash
#
# Runs deploy.sh against a fake API. The action cannot be proved end to end
# without a real control plane, but its protocol and every failure path can be,
# and those are where a deploy script actually goes wrong: a misread status
# code, a swallowed reason, a success reported before anything shipped.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
PASS=0
FAIL=0

ok() { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

# A minimal ELF header, which is all the pre-flight check reads.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
printf '\177ELF\002\001\001\000%.0s' 1 > "$WORK/server"
head -c 512 /dev/zero >> "$WORK/server"
printf 'not an executable\n' > "$WORK/mach-o"

# start_api sets API_PID and PORT. It deliberately does not return the port
# through a command substitution: the backgrounded server would inherit that
# subshell's stdout, and the substitution would block until the server exited.
start_api() { # <scenario>
  : > "$WORK/port"
  SCENARIO=$1 python3 test/fake_api.py > "$WORK/port" 2>/dev/null &
  API_PID=$!
  PORT=""
  for _ in $(seq 1 50); do
    PORT=$(head -1 "$WORK/port" 2>/dev/null)
    [[ -n $PORT ]] && break
    sleep 0.1
  done
}

stop_api() { kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; }

# run <scenario> <artifact> [env overrides…] → sets OUT and CODE
run() {
  local scenario=$1 artifact=$2; shift 2
  start_api "$scenario"
  [[ -n $PORT ]] || { bad "$scenario" "the fake API did not start"; CODE=1; OUT=""; return; }

  OUT=$(env \
    ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$PORT/token?x=1" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
    HOMEPORT_API="http://127.0.0.1:$PORT" \
    HOMEPORT_AUDIENCE="https://api.homeport.sh" \
    HOMEPORT_APP="website" \
    HOMEPORT_ARTIFACT="$artifact" \
    HOMEPORT_TIMEOUT="20" \
    GITHUB_OUTPUT="$WORK/output" \
    "$@" \
    bash "$ROOT/deploy.sh" 2>&1)
  CODE=$?
  stop_api
}

expect_ok() { # <name> <substring>
  if [[ $CODE -eq 0 ]] && grep -qF "$2" <<<"$OUT"; then ok "$1"
  else bad "$1" "exit $CODE: $(tr '\n' ' ' <<<"$OUT")"; fi
}

expect_fail() { # <name> <substring>
  if [[ $CODE -ne 0 ]] && grep -qF "$2" <<<"$OUT"; then ok "$1"
  else bad "$1" "exit $CODE, wanted a failure mentioning '$2': $(tr '\n' ' ' <<<"$OUT")"; fi
}

printf 'deploy.sh\n'

run happy "$WORK/server"
expect_ok "a clean deploy reports live" "is live"

# The status line matters: a workflow that goes green at the upload is lying.
if grep -q '^deployment-id=d-1$' "$WORK/output" && grep -q '^status=live$' "$WORK/output"; then
  ok "outputs carry the deployment id and status"
else
  bad "outputs carry the deployment id and status" "$(cat "$WORK/output" 2>/dev/null)"
fi

run slow "$WORK/server"
expect_ok "a deploy still in flight is waited for" "is live"

run deploy-fails "$WORK/server"
expect_fail "a failed deploy fails the job with the box's reason" "health check failed: 502"

run not-authorized "$WORK/server"
expect_fail "an unauthorised repository is told so" "not authorised to deploy"

run box-not-ready "$WORK/server"
expect_fail "a box that is not ready is reported" "box is not ready"

run bad-artifact "$WORK/server"
expect_fail "a rejected artifact carries the API's reason" "does not match the box architecture"

# Caught before a byte is uploaded — a macOS build is the classic mistake.
run happy "$WORK/mach-o"
expect_fail "a non-ELF artifact is refused locally" "not a Linux (ELF) executable"

run happy "$WORK/missing"
expect_fail "a missing artifact names the build step" "did the build step run"

# Without id-token: write there is no token, and the reason should say that
# rather than surfacing as an authentication failure later.
run happy "$WORK/server" ACTIONS_ID_TOKEN_REQUEST_URL= ACTIONS_ID_TOKEN_REQUEST_TOKEN=
expect_fail "a job without id-token permission says so" "id-token: write"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
