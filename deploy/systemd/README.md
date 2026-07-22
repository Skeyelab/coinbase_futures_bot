# systemd user units (deployment)

Canonical units for running the bot as a systemd **user** service stack. Until
now these lived only on the box (`~/.config/systemd/user/`), so gaps were
invisible to review — see #417, where the deploy was missing `cfb-signals`
entirely, so `SignalAlert` records were never created and `eval.last_eval_at`
went permanently stale while the bot looked healthy.

Paths use the systemd `%h` specifier (user home); the repo is assumed at
`%h/coinbase_futures_bot`. Adjust if your checkout differs.

## The stack

| Unit | Runs | Provides |
|---|---|---|
| `cfb-realtime` | `rails real_time:start` | WS market-data feed + tick path (`RapidSignalEvaluationJob`) |
| `cfb-signals`  | `rails realtime:signal_job` | signal-eval loop (`RealTimeSignalJob` → `SignalAlert`s + `eval.last_eval_at`). Reads market data from `cfb-realtime`. |
| `cfb-worker`   | `good_job start` | GoodJob cron + async jobs |
| `cfb-web`      | `rails server` | dashboard + Slack inbound endpoint |

`cfb-realtime` (tick → execute) and `cfb-signals` (batch → SignalAlert audit)
are complementary. The signal loop creates records; it does **not** place
orders (execution is the tick/cron path). Bot runs dry-run by default.

## Install / update

```bash
mkdir -p ~/.config/systemd/user
cp deploy/systemd/cfb-*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now cfb-realtime cfb-signals cfb-worker cfb-web
loginctl enable-linger "$USER"   # keep services running when logged out
```

Verify: `bin/futuresbot status` — `eval` age should track the signal loop
interval (~30s), not go stale.
