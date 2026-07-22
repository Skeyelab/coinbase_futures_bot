# Database backups (issue #414)

All production state lives in one Postgres on exo-mini (Docker, `cfb-postgres`).
Some of it **cannot be reconstructed from any external source**, and losing it
would be silent — a backtest would model funding as zero and produce a confident
wrong number.

## What this protects

| Tier | Tables | Recoverability |
|---|---|---|
| **1** | `funding_rates`, `positions`, `orders`, `signal_alerts`, `sentiment_events`, `sentiment_aggregates`, `bot_runtime_stats` | **None.** No external source exists. |
| 2 | `candles` | Refetchable from Coinbase, but BIP 1m alone is ~1,750 requests / ~40 min. |
| 3 | `contracts`, `underlyings`, `trading_pairs`, `good_job_*` | Trivially rebuilt (`upsert_products`). |

Tier 1 backs up **hourly**, matching the granularity funding settles at. The
full database backs up **nightly**.

## Design notes

**Dumps stream straight into restic over stdin** and never touch disk. exo-mini's
root filesystem runs ~70% full; a temp dump of `candles` would be the largest
single file on it.

**`pg_dump` runs via `docker exec`** — it is not installed on the host.

**Destinations are pluggable.** restic only cares about `RESTIC_REPOSITORY`, so
an SFTP host and a cloud bucket differ by config, not by code. Units are systemd
templates instantiated per destination — `cfb-backup-tier1@hermes` — and the
instance name selects the Doppler secrets (`RESTIC_*_HERMES`).

**Custom-format dumps (`-Fc`)** so `pg_restore` can pull a single table. The
common restore is "get `funding_rates` back", not "rebuild the world".

## Setup

### 1. Secrets in Doppler

Secrets live in Doppler (`coinbase-futures-bot` / `dev`) and are injected by
`doppler run` in the systemd units. Nothing sensitive is written to disk.

That is not incidental. `RESTIC_PASSWORD` is **unrecoverable** — lose it and the
repository is permanently unreadable. Keeping it only on exo-mini would mean the
box failure this system exists to survive could also destroy the ability to read
the backups. The secret must not live only where it is used.

Names are suffixed per destination, so several repos coexist in one config:

```sh
doppler secrets set --project coinbase-futures-bot --config dev \
  RESTIC_REPOSITORY_HERMES="sftp:skeyelab@hermes:/home/skeyelab/backups/cfb"

# Generate the password and store it WITHOUT echoing it to a terminal or shell
# history. Copy it into your password manager from Doppler afterwards.
openssl rand -base64 48 | doppler secrets set --project coinbase-futures-bot \
  --config dev RESTIC_PASSWORD_HERMES
```

`SENTRY_DSN` is already in that config and is picked up automatically.

> **⚠️ Also store `RESTIC_PASSWORD_HERMES` in your password manager.** Doppler is
> a single point of failure for it too — a lockout or a deleted project would
> leave the repository unreadable. Two independent copies, minimum.

**Why hermes:** it is a genuinely separate site, not a second box in the same
room. exo-mini egresses via `66.205.x`, hermes via `73.50.x`, different LANs,
reachable over Tailscale. That covers the realistic failure — exo-mini's disk or
its Docker volume dying — with encrypted transit and no third-party storage bill.

<details>
<summary>Adding a second destination later (e.g. Backblaze B2)</summary>

**No code change required** — that is the point of the template units. Set
`RESTIC_REPOSITORY_B2`, `RESTIC_PASSWORD_B2`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`
in the same Doppler config, then
`systemctl --user enable --now cfb-backup-tier1@b2.timer`.

It buys the one thing hermes cannot: surviving the loss of *both* boxes. At this
data volume, roughly $0.10/month.
</details>

<details>
<summary>Fallback: plaintext env file (recovery scenarios)</summary>

If Doppler is unavailable — a fresh box where fetching secrets is itself the
broken thing — the script falls back to `~/.config/cfb-backup/<dest>.env`
(mode `0600`, never committed):

```sh
RESTIC_REPOSITORY=sftp:skeyelab@hermes:/home/skeyelab/backups/cfb
RESTIC_PASSWORD=<from your password manager>
```
</details>

### 2. Initialise the repository

```sh
ssh skeyelab@hermes 'mkdir -p /home/skeyelab/backups/cfb'

doppler run --project coinbase-futures-bot --config dev -- \
  env RESTIC_REPOSITORY="$RESTIC_REPOSITORY_HERMES" \
      RESTIC_PASSWORD="$RESTIC_PASSWORD_HERMES" \
  restic init
```

### 3. Install and enable the units

```sh
mkdir -p ~/.config/systemd/user
cp ~/coinbase_futures_bot/ops/backup/systemd/*.service ~/.config/systemd/user/
cp ~/coinbase_futures_bot/ops/backup/systemd/*.timer   ~/.config/systemd/user/
systemctl --user daemon-reload

# One timer instance per destination. `hermes` matches the Doppler suffix
# RESTIC_*_HERMES, so adding a destination is a secret plus a timer.
systemctl --user enable --now cfb-backup-tier1@hermes.timer
systemctl --user enable --now cfb-backup-full@hermes.timer

# Survive logout — otherwise user timers stop when the session ends.
loginctl enable-linger skeyelab
```

### 4. Verify before trusting it

```sh
systemctl --user start cfb-backup-tier1@hermes.service
journalctl --user -u cfb-backup-tier1@hermes.service -n 40 --no-pager
systemctl --user list-timers 'cfb-backup*'
```

## Restore

**Always restore into a scratch database first.** Never `pg_restore` over a live
one to "check something".

> **Verified end-to-end on 2026-07-22.** A tier-1 snapshot restored into a
> scratch database matched live exactly — `funding_rates` 56/56, `positions`
> 3/3. The first attempt *failed* (wrong `restic dump` argument), which is the
> entire argument for exercising this rather than assuming it.

```sh
# Load the repo credentials from Doppler for an ad-hoc restic session
export RESTIC_REPOSITORY=$(doppler secrets get RESTIC_REPOSITORY_HERMES \
  --project coinbase-futures-bot --config dev --plain)
export RESTIC_PASSWORD=$(doppler secrets get RESTIC_PASSWORD_HERMES \
  --project coinbase-futures-bot --config dev --plain)

SNAP=$(restic snapshots --tag tier1 --latest 1 --json \
  | grep -o '"short_id":"[^"]*"' | head -1 | cut -d'"' -f4)

# Dump the SPECIFIC file path, not "/" — restic emits a tar archive when asked
# for a directory, and pg_restore fails with "could not find header for file
# toc.dat in tar archive". Verified the hard way on 2026-07-22.
FILE=$(restic ls "$SNAP" --json | grep -o '"path":"[^"]*"' | tail -1 | cut -d'"' -f4)

restic dump "$SNAP" "$FILE" > /tmp/restore.dump

docker exec cfb-postgres createdb -U postgres cfb_restore_check
docker cp /tmp/restore.dump cfb-postgres:/tmp/restore.dump
docker exec cfb-postgres pg_restore -U postgres -d cfb_restore_check /tmp/restore.dump

# Assert it actually contains what you think it does
docker exec cfb-postgres psql -U postgres -d cfb_restore_check \
  -c "select count(*), min(funding_time), max(funding_time) from funding_rates;"
```

Single table back into the live database:

```sh
docker exec cfb-postgres pg_restore -U postgres -d coinbase_futures_bot_development \
  --table=funding_rates --data-only /tmp/restore.dump
```

## Monitoring

- **Run failure** → `OnFailure=` fires `cfb-backup-alert@`, which reports to
  Sentry with `component:backup`. It uses plain curl and does **not** boot Rails:
  this runs when something is already broken, and a notifier that needs a healthy
  app to report an unhealthy one is not a notifier.
- **Hourly timer silently stopped** → the nightly full run asserts the newest
  `tier1` snapshot is under 3h old and fails loudly if not.

### Known gap

**Nothing watches the nightly run itself.** If the whole box dies or systemd
never fires the timer, no alert is raised — silence is indistinguishable from
success. Closing that needs an external dead-man's switch (healthchecks.io or
similar) pinged on success, alerting when the ping stops. Deliberately deferred:
it is the only piece requiring a third-party account, and the failure it covers
(total host loss) is also the loudest one operationally.

## Cost and size

Storage on hermes is free (195 GB available). Size is modest: tier 1 is tiny —
`funding_rates` grows ~28 rows/hour, ~245k/year — and even with a year of BIP 1m
candles the repository stays well under a gigabyte. restic deduplicates, so
hourly snapshots of slowly-changing tables cost almost nothing beyond the first.
