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
B2 and an SFTP host differ by config, not by code. Units are systemd templates
instantiated per destination: `cfb-backup-tier1@b2`, `cfb-backup-full@hermes`.

**Custom-format dumps (`-Fc`)** so `pg_restore` can pull a single table. The
common restore is "get `funding_rates` back", not "rebuild the world".

## Setup

### 1. Config per destination

`~/.config/cfb-backup/<destination>.env`, mode `0600`. Never commit these.

**Backblaze B2** (`~/.config/cfb-backup/b2.env`):

```sh
RESTIC_REPOSITORY=b2:YOUR-BUCKET-NAME:/exo-mini
RESTIC_PASSWORD=<long random string — SEE WARNING BELOW>
B2_ACCOUNT_ID=<application key id>
B2_ACCOUNT_KEY=<application key>
SENTRY_DSN=<same DSN the app uses>
```

**hermes over SFTP** (`~/.config/cfb-backup/hermes.env`):

```sh
RESTIC_REPOSITORY=sftp:skeyelab@hermes:/home/skeyelab/backups/cfb
RESTIC_PASSWORD=<long random string>
SENTRY_DSN=<same DSN the app uses>
```

> **⚠️ `RESTIC_PASSWORD` is not recoverable.** Lose it and the repository is
> permanently unreadable — that is the whole point of the encryption. Store it
> in your password manager **before** running `init`, not after. A backup you
> cannot decrypt is indistinguishable from no backup.

```sh
chmod 700 ~/.config/cfb-backup && chmod 600 ~/.config/cfb-backup/*.env
```

### 2. Initialise each repository

```sh
set -a; source ~/.config/cfb-backup/b2.env; set +a
restic init

# hermes needs the target directory to exist first
ssh skeyelab@hermes 'mkdir -p /home/skeyelab/backups/cfb'
set -a; source ~/.config/cfb-backup/hermes.env; set +a
restic init
```

### 3. Install and enable the units

```sh
mkdir -p ~/.config/systemd/user
cp ~/coinbase_futures_bot/ops/backup/systemd/*.service ~/.config/systemd/user/
cp ~/coinbase_futures_bot/ops/backup/systemd/*.timer   ~/.config/systemd/user/
systemctl --user daemon-reload

# One instance per destination.
systemctl --user enable --now cfb-backup-tier1@b2.timer
systemctl --user enable --now cfb-backup-full@b2.timer

# Optional second destination (3-2-1).
systemctl --user enable --now cfb-backup-tier1@hermes.timer
systemctl --user enable --now cfb-backup-full@hermes.timer

# Survive logout — otherwise user timers stop when the session ends.
loginctl enable-linger skeyelab
```

### 4. Verify before trusting it

```sh
systemctl --user start cfb-backup-tier1@b2.service
journalctl --user -u cfb-backup-tier1@b2.service -n 40 --no-pager
restic snapshots --tag tier1
systemctl --user list-timers 'cfb-backup*'
```

## Restore

**Always restore into a scratch database first.** Never `pg_restore` over a live
one to "check something".

```sh
set -a; source ~/.config/cfb-backup/b2.env; set +a
restic snapshots --tag tier1                       # pick a snapshot id
restic dump <snapshot-id> latest > /tmp/restore.dump

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

## Cost

Tier 1 is tiny — `funding_rates` grows ~28 rows/hour, ~245k/year. Even with a
year of candles the repository is well under 1 GB, so B2 runs to roughly
**$0.10/month**. restic deduplicates, so hourly snapshots of a slowly-changing
table cost almost nothing beyond the first.
