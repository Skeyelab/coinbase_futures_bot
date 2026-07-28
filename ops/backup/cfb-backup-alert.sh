#!/bin/bash
#
# systemd OnFailure handler for the backup timers (issue #414).
#
# Reports to Sentry via the store endpoint using plain curl. Deliberately does
# NOT boot Rails: this runs precisely when something is already broken, and a
# notifier that needs a healthy app to report an unhealthy one is not a notifier.
#
# Usage: cfb-backup-alert.sh <failed-unit-name>

set -uo pipefail

UNIT="${1:-unknown}"
CONFIG="${CFB_BACKUP_ENV:-/etc/cfb-backup.env}"
if [[ -r "$CONFIG" ]]; then
  set -a
  # shellcheck disable=SC1090  # path is a runtime-chosen destination config
  source "$CONFIG"
  set +a
fi

JOURNAL="$(journalctl --user -u "$UNIT" -n 30 --no-pager 2>/dev/null | tail -c 3000)"
echo "[cfb-backup-alert] $UNIT failed"

if [[ -z "${SENTRY_DSN:-}" ]]; then
  echo "[cfb-backup-alert] SENTRY_DSN unset -- failure logged to journal only" >&2
  exit 0
fi

# Split a DSN of the form https://<key>@<host>/<project_id>
key="$(sed -E 's#^https://([^@]+)@.*#\1#' <<<"$SENTRY_DSN")"
host="$(sed -E 's#^https://[^@]+@([^/]+)/.*#\1#' <<<"$SENTRY_DSN")"
project="$(sed -E 's#.*/##' <<<"$SENTRY_DSN")"

payload=$(cat <<JSON
{
  "level": "error",
  "logger": "cfb-backup",
  "platform": "other",
  "server_name": "exo-mini",
  "message": {"formatted": "Backup unit ${UNIT} FAILED — database backups are not running"},
  "tags": {"component": "backup", "unit": "${UNIT}", "issue": "414"},
  "extra": {"journal_tail": $(jq -Rs . <<<"$JOURNAL" 2>/dev/null || echo '"unavailable"')}
}
JSON
)

# Retried, because the conditions that trigger this alert overlap heavily with
# the conditions that break it. On 2026-07-28 a ~5 minute network outage failed
# the hourly backup AND this notification -- one 15s attempt, then silence, with
# systemd still reporting the alert unit successful (issue #519). The outage was
# transient; the next backup succeeded 57 minutes later.
#
# Still exits 0 in every case: an alerter that fails its own unit turns one
# incident into two. The abandonment message is the operator's only signal that
# a failure went unreported, so it must be unambiguous.
send_to_sentry() {
  curl -sf --max-time 15 \
    -X POST "https://${host}/api/${project}/store/" \
    -H "Content-Type: application/json" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=${key}, sentry_client=cfb-backup/1.0" \
    -d "$payload" >/dev/null
}

ATTEMPTS="${CFB_ALERT_ATTEMPTS:-4}"
BACKOFF="${CFB_ALERT_BACKOFF_SECONDS:-10}"

for attempt in $(seq 1 "$ATTEMPTS"); do
  if send_to_sentry; then
    echo "[cfb-backup-alert] reported to Sentry (attempt ${attempt}/${ATTEMPTS})"
    exit 0
  fi
  if (( attempt < ATTEMPTS )); then
    echo "[cfb-backup-alert] Sentry send failed (attempt ${attempt}/${ATTEMPTS}), retrying in ${BACKOFF}s" >&2
    sleep "$BACKOFF"
    BACKOFF=$(( BACKOFF * 2 ))
  fi
done

echo "[cfb-backup-alert] GAVE UP after ${ATTEMPTS} attempts -- ${UNIT} failed and was NOT reported to Sentry; check the journal directly" >&2

exit 0
