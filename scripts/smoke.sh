#!/usr/bin/env bash
# Post-build smoke test. Runs against a built image (arg 1) before anything is pushed:
# a published digest that fails these is worse than no publish at all.
set -euo pipefail

IMG="${1:?usage: smoke.sh <image-ref>}"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

# A2 - python and the pins that everything else assumes
docker run --rm "$IMG" python -V 2>&1 | grep -q "Python 3.13" || fail "python is not 3.13"
docker run --rm "$IMG" python - <<'PY' || fail "core pins do not import"
import pandas, numpy, scipy, statsmodels, duckdb, polars
print("pandas", pandas.__version__, "numpy", numpy.__version__, "scipy", scipy.__version__)
PY
ok "python + core pins"

# the new deps exist and are importable
docker run --rm "$IMG" python -c "import jupytext, nbgitpuller, polars, duckdb; print('extras ok')" \
  || fail "research extras missing"
ok "research extras"

# A11 - no escalation path from a notebook
if docker run --rm "$IMG" sh -c 'command -v sudo' 2>/dev/null | grep -q .; then
  fail "sudo is present in the image"
fi
ok "no sudo"

# supercronic installed and executable for this arch
docker run --rm "$IMG" supercronic -version >/dev/null || fail "supercronic not runnable"
docker run --rm "$IMG" test -f /etc/supercronic/crontab || fail "crontab missing"
ok "supercronic"

# the verifier path the deploy depends on: jupyter_server imports argon2 with no fallback, so a
# missing argon2-cffi fails the password step at the last moment. Assert the real call, not the import.
alg=$(docker run --rm "$IMG" python -c \
  'from jupyter_server.auth.security import passwd; print(passwd("smoke").split(":")[0])' 2>/dev/null || true)
[ "$alg" = "argon2" ] || fail "jupyter_server.auth.passwd did not produce an argon2 verifier (got '${alg:-none}')"
ok "argon2 verifier"

# identity is the build arg, not a leftover literal
docker run --rm "$IMG" id -u | grep -qx "1500" || fail "container uid is not 1500"
ok "uid 1500"

# A13 - no host socket reachable
docker run --rm "$IMG" sh -c 'test ! -e /var/run/docker.sock' || fail "docker.sock present"
ok "no docker socket"

# the server actually serves; /api is unauthenticated and returns 200
cid=$(docker run -d -p 18899:8888 "$IMG")
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18899/api || true)
  [ "$code" = "200" ] && break
  sleep 2
done
[ "${code:-}" = "200" ] || fail "/api did not return 200 (got ${code:-none})"
ok "/api 200"

# A8 - auth is enforced: /lab must redirect to login, not serve the app
lab=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18899/lab || true)
[ "$lab" = "302" ] || fail "/lab returned $lab, expected 302 to login"
ok "/lab gated"

echo "smoke: all checks passed"
