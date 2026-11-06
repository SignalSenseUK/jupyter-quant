#!/usr/bin/env bash
# P1 - equities/ETF update. Wrapper exists so the schedule, the healthcheck ping and the
# fail-closed behaviour are all in one reviewable place rather than in a crontab line.
set -euo pipefail

CHECKOUT="${QR_EQUITY_CHECKOUT:-/home/quant/Notebooks/finance-data-download}"
CONFIG="${QR_EQUITY_CONFIG:-/store/data/equities_etf.json}"
HC="${HC_EQUITY:-}"

ping() { [ -n "$HC" ] && curl -fsS -m 10 -o /dev/null --data-raw "$1" "$HC" || true; }
fail_ping() { [ -n "$HC" ] && curl -fsS -m 10 -o /dev/null --data-raw "$1" "${HC%/}/fail" || true; }

[ -d "$CHECKOUT" ] || { echo "missing checkout: $CHECKOUT" >&2; fail_ping "checkout missing"; exit 1; }
VENV="$CHECKOUT/.venv/bin/finance-download"
[ -x "$VENV" ] || { echo "missing entrypoint: $VENV" >&2; fail_ping "venv missing"; exit 1; }
[ -f "$CONFIG" ] || { echo "missing config: $CONFIG" >&2; fail_ping "config missing"; exit 1; }

# A swallowed git pull hides the ticker list going stale - make it fatal (spec 9.1).
cd "$(dirname "$CONFIG")" || exit 1
git pull --ff-only origin main || { echo "git pull failed" >&2; fail_ping "config pull failed"; exit 1; }

echo "[$(date -Iseconds)] equity update starting"
"$VENV" run --config "$CONFIG"
echo "[$(date -Iseconds)] equity update finished"
ping "equity update ok $(date -Iseconds)"
