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

curl -sf --max-time 15 \
  -X POST "https://${host}/api/${project}/store/" \
  -H "Content-Type: application/json" \
  -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=${key}, sentry_client=cfb-backup/1.0" \
  -d "$payload" >/dev/null \
  && echo "[cfb-backup-alert] reported to Sentry" \
  || echo "[cfb-backup-alert] Sentry report FAILED -- check the journal directly" >&2

exit 0
