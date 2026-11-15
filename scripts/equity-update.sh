#!/usr/bin/env bash
# P1 - equities/ETF update. Wrapper exists so the schedule, the healthcheck ping and the
# fail-closed behaviour are all in one reviewable place rather than in a crontab line.
set -euo pipefail

CHECKOUT="${QR_EQUITY_CHECKOUT:-/home/quant/Notebooks/finance-data-download}"
CONFIG="${QR_EQUITY_CONFIG:-/store/data/equities_etf.json}"
STORE="$(dirname "$CONFIG")"
HC="${HC_EQUITY:-}"

ping() { [ -n "$HC" ] && curl -fsS -m 10 -o /dev/null --data-raw "$1" "$HC" || true; }
fail_ping() { [ -n "$HC" ] && curl -fsS -m 10 -o /dev/null --data-raw "$1" "${HC%/}/fail" || true; }

[ -d "$CHECKOUT" ] || { echo "missing checkout: $CHECKOUT" >&2; fail_ping "checkout missing"; exit 1; }
VENV="$CHECKOUT/.venv/bin/finance-download"
[ -x "$VENV" ] || { echo "missing entrypoint: $VENV" >&2; fail_ping "venv missing"; exit 1; }
[ -f "$CONFIG" ] || { echo "missing config: $CONFIG" >&2; fail_ping "config missing"; exit 1; }

# The downloader's log lives in the checkout. Git tracks no file in it (every entry matches
# *.log), so a re-clone leaves the directory absent and loguru fails at import - create it
# rather than depending on the tar that happened to carry it.
mkdir -p "$CHECKOUT/logs"

# A swallowed git pull hides the ticker list going stale - make it fatal (spec 9.1).
# A failed ff-pull also means an earlier run left commits local-only: drain them and retry,
# otherwise every later run fails on the same unpushed commit and the store stops advancing.
cd "$STORE" || exit 1
if ! git pull --ff-only origin main; then
  git push origin main || { echo "pull failed and the local commits cannot be pushed" >&2; fail_ping "stuck: unpushed data commits"; exit 1; }
  git pull --ff-only origin main || { echo "git pull failed after draining local commits" >&2; fail_ping "config pull failed"; exit 1; }
fi

echo "[$(date -Iseconds)] equity update starting"
"$VENV" run --config "$CONFIG"

# Publish. This wrapper is the node's only committer: nothing else on bero2 pushes the store,
# and a run that writes rows without pushing them is invisible to every consumer that pulls.
# EOD prices only - dividend files carry announced *future* ex-dates and would misdate the stamp.
NEWEST="$(grep -h '"last_data_date"' "$STORE"/equities/eod/*/*_eod_prices.meta.json | awk -F'"' '{print $4}' | sort | tail -1)" || true

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "Data updates ${NEWEST}" || { echo "git commit failed" >&2; fail_ping "commit failed"; exit 1; }
  git push origin main || { echo "git push failed at $(git rev-parse --short HEAD)" >&2; fail_ping "push failed at $(git rev-parse --short HEAD)"; exit 1; }
else
  echo "no data changes to commit"
fi

echo "[$(date -Iseconds)] equity update finished"
ping "equity update ok newest=${NEWEST} $(date -Iseconds)"
