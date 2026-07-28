# ADR 0005: Control Planes and Trading-State Authorization

**Date:** 2026-07-28
**Status:** Accepted

## Context

ADRs 0001–0004 record trading decisions — what an order is, which venue, which risk machinery, which contracts. **None of them records who may pull the levers.** Six surfaces reach `TradingHalt` and `Trading::CoinbasePositions`, and every one of them arrived without a decision behind it. The result is six different authorization models on the same primitives, three of which fail open.

Audited 2026-07-27/28, all verified in code:

| Surface | Entry point | Can mutate | Authorization | Fails |
|---|---|---|---|---|
| Web positions UI | `positions_controller.rb` | open, increase, close | HTTP basic, `secure_compare`, renders `:forbidden` when creds unset (`:118-131`) | **closed** |
| Position import | `position_import_controller.rb` | rewrites the `positions` table | HTTP basic, but `return if Rails.env.development?` (`:61`) and plain `==` not `secure_compare` | closed in prod, weaker |
| CLI | `lib/cli/futures_bot_cli.rb` | halt, resume, `dry_run_off` | none — OS process ownership | n/a (local) |
| TUI | `lib/tui/` | halt toggle, close | none — OS process ownership | n/a (local) |
| MCP | `app/services/mcp/server.rb` | halt, resume, close | none; `close_position` gated on `confirm: true` (`:104-106`) | **open** |
| Slack | `slack_controller.rb`, `slack_command_handler.rb` | halt, resume | `return true unless ENV["SLACK_SIGNING_SECRET"].present?` (`:149`); `return true if authorized_users.empty?` (`:47`) | **open** |
| Signals API | `signal_controller.rb` | read-only | `return if expected_key.nil?` (`:284`), plus `Access-Control-Allow-Origin: *` (`:292`) | **open** |
| Chat API | `chat_bot_service.rb`, `api/chat_messages_controller.rb` | **was** halt, resume, "emergency stop" | none whatsoever | **open** |

Two failures already found and fixed, both of which this ADR exists to prevent recurring:

1. **The chat surface was an unauthenticated remote kill switch.** `POST /api/chat_messages` inherits `ActionController::API` — no auth, no CSRF — and its only `before_action`s are `ensure_json_request`, `set_session_id`, `set_chat_bot_service`. It reached `TradingHalt.halt!` and `resume!`. Worse, intent was matched by regex over the *model's own response* (`parse_ai_response` cases on `content`, not on operator input), so any prompt that induced the model to echo "emergency stop" fired it.

2. **Two "emergency stops" halted trading and lied about the book.** Both `slack_command_handler.rb` and `chat_bot_service.rb` walked open positions incrementing a counter with `position.close!` commented out, then reported "Emergency stop completed successfully — Positions closed: N". Halting while claiming the book is flat is the dangerous half: the operator reads "flat" and walks away from open leveraged positions. Two specs asserted the fabricated count.

One thing that did hold, and is worth naming because it is the pattern to copy: `TradingHalt` defends itself. `resume!` raises `RiskHaltError` without `acknowledge_risk: true`, and `halt!` will not downgrade an active risk halt (`:132`). So even the unauthenticated path could never clear a loss-cap trip. The primitive was safe; the surfaces around it were not.

The generalisation: **an LLM classifier is the wrong mechanism for a control action regardless of who is authenticated.** Authentication establishes *who*; it does not establish *did they mean it*. A surface whose input is inferred rather than stated should not mutate money-touching state at all.

## Decision

**Every surface is classified as READ-ONLY, OPERATOR, or ENGINE with respect to trading state. Mutation is a property a surface must earn, not a default.**

**READ-ONLY** — may read any state, may mutate none. Includes the chat API, the signals API, and any future dashboard. Anything whose input is inferred by a model is permanently read-only. Recognise the intent and decline by name, pointing at a surface that can act; do not silently drop it.

**OPERATOR** — may halt, resume, and close, with a deliberate, stated action from an authenticated human. Currently the CLI, TUI, MCP, and web positions UI. Requirements:

- **Authorization fails closed.** A missing secret denies the request; it never grants it. `return true unless ENV[...]` is forbidden. `positions_controller.rb:118-131` is the reference implementation: `secure_compare`, and `:forbidden` when unconfigured.
- **Local surfaces (CLI, TUI) rely on OS process ownership** and need no application auth. Remote surfaces (HTTP, Slack, MCP over a socket) need it.
- **Money-touching actions require explicit confirmation** — `confirm: true`, a typed reason, or an interactive prompt. `Mcp::Server#close_position` is the reference.
- **Closes route through `Trading::PositionLifecycle`**, never `CoinbasePositions` directly, so exits feed the cooldown, stoploss guard, and daily loss caps (ADR 0003).

**ENGINE** — the automated path. `RapidSignalEvaluationJob` → `Trading::CoinbasePositions`. Not a control plane; governed by ADR 0003.

**Two rules bind all three classes:**

1. **No surface may report an action it did not perform.** If it cannot do the thing, it says so. A control that reports success it did not achieve is worse than one that is absent, because the operator stops looking.
2. **A new mutating surface requires an ADR.** Adding one is a decision, not an implementation detail. This is the rule whose absence produced the table above.

Slack is currently in violation: both auth layers fail open. It is demoted to READ-ONLY plus outbound notification until they fail closed, at which point it may be promoted back to OPERATOR by amendment.

## Implementation status

As of 2026-07-28, partially enforced. Recorded explicitly so this ADR is not mistaken for protection it does not yet provide:

| Decision | State |
|---|---|
| Chat is READ-ONLY | **built** — `chat_bot_service.rb`, commit `b817863` |
| No surface reports an action it did not perform | **built** for both emergency stops — commits `b817863`, `ad02b8e` |
| Operator closes route through `PositionLifecycle` | **built** for MCP, TUI, web — commit `5c01d0a`; partial reduces still bypass it |
| Slack auth fails closed | **not built** — `slack_controller.rb:149` and `slack_command_handler.rb:47` still fail open, so Slack's demotion to READ-ONLY is policy, not code |
| `signal_controller.rb` fails closed, CORS narrowed | **not built** |
| `position_import_controller.rb` uses the `positions_controller` auth pattern | **not built** |
| A new mutating surface requires an ADR | process rule; no mechanism |

## Consequences

- The chat surface loses halt/resume/emergency-stop; `execute_start_trading_command`, `execute_stop_trading_command`, `execute_emergency_stop_command`, `execute_emergency_stop_internal`, and `set_trading_status` are deleted. It keeps read-only status and position-sizing reporting.
- Slack `/bot-stop` halts and states what remains open rather than claiming a close. `/bot-pause` and `/bot-resume` remain pending the fail-closed fix.
- `signal_controller.rb`'s fail-open key and wildcard CORS become defects with a rule behind them rather than an accepted quirk.
- MCP has no transport auth. It is accepted as OPERATOR only because it is stdio over a local process, which makes it equivalent to the CLI. **If MCP is ever exposed over a network socket, this ADR is violated** and it must gain authentication first.
- `position_import_controller.rb`'s `return if Rails.env.development?` and plain `==` should move to the `positions_controller` pattern.
- Capability is duplicated across surfaces. This ADR governs authorization only; whether six surfaces should exist at all is a separate question, and the read-only ones are the obvious candidates for deletion.
