#!/bin/bash
#
# Postgres -> restic -> one or more offsite repos (issue #414).
#
# Backs up the one database holding data no external source can rebuild: funding
# history (the products API exposes only the current interval), real execution
# history, and the signal/sentiment record. Candles are recoverable from
# Coinbase; everything in TIER1_TABLES is not.
#
# Modes:
#   tier1  hourly, irreplaceable tables only. Small and fast, so worst-case loss
#          is bounded to an hour -- the granularity funding itself settles at.
#   full   nightly, whole database including candles. Turns a rebuild from "days
#          of refetching" into a restore.
#
# Destinations are pluggable because restic only cares about RESTIC_REPOSITORY.
# Each destination has its own env file, so B2 and an SFTP host differ by
# configuration rather than by code.
#
# The dump streams directly into restic over stdin and never touches disk --
# deliberate, because exo-mini's root filesystem runs ~70% full and a temp dump
# of the candles table would be the largest single file on it.
#
# Usage:  cfb-backup.sh {tier1|full} <destination>
# Config: ~/.config/cfb-backup/<destination>.env   (see README.md)

set -euo pipefail

MODE="${1:-}"
DEST="${2:-}"

if [[ "$MODE" != "tier1" && "$MODE" != "full" ]] || [[ -z "$DEST" ]]; then
  echo "usage: $(basename "$0") {tier1|full} <destination>" >&2
  exit 64
fi

CONFIG_DIR="${CFB_BACKUP_CONFIG_DIR:-$HOME/.config/cfb-backup}"
CONFIG="$CONFIG_DIR/$DEST.env"
if [[ ! -r "$CONFIG" ]]; then
  echo "FATAL: no config for destination '$DEST' at $CONFIG" >&2
  exit 78
fi
set -a
# shellcheck disable=SC1090  # path is a runtime-chosen destination config
source "$CONFIG"
set +a

: "${RESTIC_REPOSITORY:?not set in $CONFIG}"
: "${RESTIC_PASSWORD:?not set in $CONFIG}"

PG_CONTAINER="${PG_CONTAINER:-cfb-postgres}"
PG_USER="${PG_USER:-postgres}"
PG_DATABASE="${PG_DATABASE:-coinbase_futures_bot_development}"

# Tables with no external source of truth, ordered by how badly losing them hurts.
#   funding_rates  - the API only ever exposes the current interval (#391, #412)
#   positions      - real fills/fees/MAE; #376 gate 4 measures parity against these
#   orders         - order-level execution record (ADR 0001)
#   signal_alerts  - what the strategy decided and when; not replayable, because
#                    the code that produced them keeps changing
#   sentiment_*    - point-in-time scored news; feeds roll off, scorers drift
#   bot_runtime_stats - suspensions/halt/dry-run/protection locks. Tiny, but
#                    losing it silently UN-suspends symbols, which is a safety
#                    failure rather than a data one.
TIER1_TABLES=(
  funding_rates
  positions
  orders
  signal_alerts
  sentiment_events
  sentiment_aggregates
  bot_runtime_stats
)

log() { echo "[cfb-backup:$MODE:$DEST] $*"; }

# pg_dump is not installed on the host -- Postgres runs in Docker. Custom format
# (-Fc) is compressed and lets pg_restore pull individual tables, which matters
# because the common restore is "get funding_rates back", not "rebuild the world".
dump_cmd=(docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DATABASE" -Fc --no-owner --no-acl)
if [[ "$MODE" == "tier1" ]]; then
  for t in "${TIER1_TABLES[@]}"; do dump_cmd+=(-t "$t"); done
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPSHOT_NAME="${PG_DATABASE}-${MODE}-${STAMP}.dump"

log "starting: repo=${RESTIC_REPOSITORY} db=${PG_DATABASE}"

# PIPESTATUS is checked explicitly: with pipefail alone, restic could still
# report success after pg_dump wrote a TRUNCATED dump and died mid-stream. A
# silently-truncated backup is worse than a failed one, so both sides must pass.
set +e
"${dump_cmd[@]}" 2> >(sed 's/^/[pg_dump] /' >&2) \
  | restic backup --stdin --stdin-filename "$SNAPSHOT_NAME" --tag "$MODE" --tag cfb --host exo-mini
status=("${PIPESTATUS[@]}")
set -e

if [[ "${status[0]}" -ne 0 ]]; then
  log "FATAL: pg_dump exited ${status[0]} -- backup is incomplete, not retrying"
  exit 1
fi
if [[ "${status[1]}" -ne 0 ]]; then
  log "FATAL: restic exited ${status[1]}"
  exit 1
fi

log "snapshot written: $SNAPSHOT_NAME"

# Retention. Hourly tier1 snapshots are tiny, so keeping 48 costs almost nothing
# and covers "the bad migration ran two days ago".
if [[ "$MODE" == "tier1" ]]; then
  restic forget --tag tier1 --keep-hourly 48 --keep-daily 14 --keep-weekly 8 --keep-monthly 12
else
  restic forget --tag full --keep-daily 14 --keep-weekly 8 --keep-monthly 12
fi

# Prune and verify only on the nightly run: both are expensive, and doing them
# hourly would burn more time and B2 transactions than the protection is worth.
if [[ "$MODE" == "full" ]]; then
  log "pruning"
  restic prune

  # Reads 5% of pack data per run, so corruption surfaces within weeks rather
  # than on the day of a restore. An unverified backup is a guess.
  log "verifying"
  restic check --read-data-subset=5%

  # The nightly run is the watchdog for the hourly one. A FAILING tier1 timer
  # raises through OnFailure, but a timer that silently stopped firing raises
  # nothing -- and that is precisely the failure mode this ticket exists for.
  # Tier1 runs hourly, so older than 3h means it is not running.
  #
  # NOTE: nothing watches THIS run in turn. Closing that loop needs an external
  # dead-man's switch -- see README, "Known gap".
  newest_tier1="$(restic snapshots --tag tier1 --latest 1 --json 2>/dev/null | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4)"
  if [[ -z "$newest_tier1" ]]; then
    log "FATAL: no tier1 snapshot exists in this repo at all"
    exit 1
  fi
  age_h=$(( ( $(date -u +%s) - $(date -u -d "$newest_tier1" +%s) ) / 3600 ))
  if (( age_h > 3 )); then
    log "FATAL: newest tier1 snapshot is ${age_h}h old -- the hourly timer is not running"
    exit 1
  fi
  log "tier1 freshness ok (${age_h}h)"
fi

log "done"
