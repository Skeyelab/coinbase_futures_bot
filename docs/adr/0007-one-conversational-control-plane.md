# ADR 0007: One Conversational Control Plane — MCP Survives, Slack Commands and the Chat API Are Deleted

**Date:** 2026-07-28
**Status:** Accepted
**Amends:** [ADR 0005](0005-control-planes-and-trading-state-authorization.md) (control-plane classification). ADR 0005 otherwise stands — its READ-ONLY / OPERATOR / ENGINE classes, its fail-closed authorization rule, its "no surface may report an action it did not perform" rule, and its "a new mutating surface requires an ADR" rule all still bind. This amendment removes two rows from its surface table rather than reclassifying them.

## Context

ADR 0005 audited eight surfaces reaching `TradingHalt` and `Trading::CoinbasePositions`, and closed with the observation it did not act on:

> Capability is duplicated across surfaces. This ADR governs authorization only; whether six surfaces should exist at all is a separate question, and the read-only ones are the obvious candidates for deletion.

This is that decision. The duplication is not incidental — it is the mechanism by which the same fact acquires several different answers.

**Two of the surfaces were routers over the same small read set.** `slack_command_handler.rb` (784 LOC) matched a slash command against a regex table; `chat_bot_service.rb` (751 LOC) plus `ai_command_processor_service.rb` (121 LOC) sent operator text to an LLM and matched the *model's reply* against a regex table. Under both, the reachable capability is the same six reads — status, positions, signals, PnL, sentiment, position sizing — plus halt and resume. `app/services/mcp/server.rb` exposes that capability in 147 LOC of pure delegation to `OperatorSnapshot`, `TradingHalt`, and `Trading::PositionLifecycle`, because it holds no formatting and no intent inference of its own.

**ADR 0005 already made the chat surface permanently read-only, and gave the reason that also forbids ever promoting it:**

> an LLM classifier is the wrong mechanism for a control action regardless of who is authenticated. Authentication establishes *who*; it does not establish *did they mean it*.

A surface that can never be promoted, and whose reads are served better by a surface that can, is carrying maintenance cost for a capability it is not allowed to have. Keeping it is not conservatism; it is a standing invitation to re-add the halt path someone deleted in commit `b817863`.

**The duplication had already produced measurable divergence.** Six position serializers and six PnL formulas existed across these surfaces, each formatting the same rows its own way. That is the class of defect ADR 0005's audit found in a different guise: two independent "emergency stop" implementations that both halted trading and both lied about the book. When N surfaces re-derive a number, the operator eventually reads two of them and believes the wrong one — and there is no test that fails when they disagree, because each surface's spec asserts its own output.

**Slack's inbound and outbound halves are separable, and only the inbound half is a control plane.** `slack_notification_service.rb` (819 LOC, 18 caller files) pushes alerts *out*; it never reads a Slack request and never mutates trading state. ADR 0005 demoted Slack to "READ-ONLY plus outbound notification" precisely because those are two different things wearing one integration's name. Deleting the command endpoint does not touch the alert path.

## Decision

**MCP is the only conversational control plane. The Slack command endpoint and the chat API are deleted, not demoted.**

The amended surface table:

| Surface | Class | State |
|---|---|---|
| Web positions UI | OPERATOR | unchanged |
| Position import | OPERATOR | unchanged |
| CLI (`bin/futuresbot`) | OPERATOR | unchanged, minus its `chat` REPL |
| TUI | OPERATOR | unchanged |
| **MCP** (`app/services/mcp/server.rb`) | **OPERATOR** | **the surviving conversational plane** |
| Signals API | READ-ONLY | unchanged |
| Slack — outbound alerts | *not a control plane* | retained; `slack_notification_service.rb` untouched |
| ~~Slack — inbound commands~~ | ~~READ-ONLY~~ | **deleted** |
| ~~Chat API~~ | ~~READ-ONLY~~ | **deleted** |

**Why MCP is the one that survives, given that ADR 0005's objection to inferred intent applies to any model-driven surface:**

1. **The inference happens outside the trust boundary, and the boundary is typed.** `Mcp::Server` receives a named tool call with a validated argument list. The model chooses the tool; it does not author the intent classifier. `slack_command_handler.rb` and `chat_bot_service.rb` both *contained* the classifier — `chat_bot_service.rb` matched on the model's own generated text, which is why any prompt that induced it to echo "emergency stop" fired the halt. Moving intent recognition outside the process is what makes MCP eligible for OPERATOR where chat is not.
2. **Money-touching actions carry explicit confirmation.** `Mcp::Server#close_position` requires `confirm: true` — ADR 0005 names it the reference implementation of that rule. Neither router had an equivalent.
3. **It delegates rather than re-deriving.** MCP's reads go through `OperatorSnapshot`, the same object that feeds the CLI and the positions table. It cannot disagree with them, because it does not compute anything to disagree with. This is the property that ends the six-serializer problem, and it is why the fix is deletion rather than a shared formatter: a formatter shared by six routers is still six routers.
4. **It is local stdio, so ADR 0005's transport caveat still governs it.** If MCP is ever exposed over a network socket it must gain authentication first. That constraint is inherited unchanged and is not weakened by MCP now being the only conversational plane — if anything it binds harder.

**Two rules added:**

5. **A conversational surface may not hold its own intent classifier.** If a surface must decide what the operator meant from free text, it is READ-ONLY at best and should not be built at all while MCP exists. This is ADR 0005's principle stated as a construction rule rather than an authorization one.
6. **A new read surface must delegate to `OperatorSnapshot`.** Re-deriving a position row, a PnL figure, or a halt reason inside a surface is what produced the divergence above. A surface that formats is fine; a surface that computes is a seventh answer waiting to happen.

**Explicitly not decided here:** whether Slack should ever regain inbound commands. ADR 0005 left promotion available by amendment once its auth failed closed, and the auth *did* subsequently fail closed (PR #512). This ADR removes the surface on duplication grounds, independent of that. Rebuilding it would be a new mutating surface and therefore requires an ADR under ADR 0005's rule 2 — which is the correct bar, because the argument for rebuilding it would have to explain what it gives the operator that MCP does not.

## Implementation status

As of 2026-07-28, this ADR is fully built. Recorded in the same form as ADR 0005 and 0006 so the gap between decision and code is visible rather than assumed.

| Decision | State |
|---|---|
| Slack command endpoint deleted | **built** — `slack_controller.rb` (255 LOC), `slack_command_handler.rb` (784 LOC), the `namespace :slack` routes, and both handler specs are gone. `POST /slack/commands`, `POST /slack/events`, and `GET /slack/health` no longer resolve. |
| Chat API deleted | **built** — `chat_bot_service.rb` (751), `ai_command_processor_service.rb` (121), `api/chat_messages_controller.rb` (99), `chat_controller.rb` (21), `app/views/chat/index.html.erb` (420), and the `/chat` and `/api/chat_messages` routes are gone. |
| CLI `chat` REPL deleted | **built** — a cascade, not a separate decision: `bin/futuresbot chat` and `rake chat_bot:start` were both thin terminals onto `ChatBotService`. They are the same AI-chat command surface in a different shell and could not survive its removal. Every other CLI verb is untouched. |
| `ChatAuditLogger` deleted | **built** — 250 LOC whose only callers were four call sites inside `chat_bot_service.rb`. It became an orphan on deletion and was removed with it. |
| AI provider keys retired | **built** — `OPENROUTER_API_KEY` and `OPENAI_API_KEY` served `AiCommandProcessorService` and have no application reader left. Commented out in `.env.example`; still set by the test harness, which asserts their presence. MCP needs no key of its own, because the model calling it lives in the client. |
| Outbound Slack alerts retained | **built** — `slack_notification_service.rb` is unmodified and its 18 caller files are unmodified. `SLACK_BOT_TOKEN` and the channel variables remain load-bearing. |
| MCP is the surviving conversational plane | **built** — `app/services/mcp/server.rb` unmodified; it did not need to grow to absorb the deleted surfaces, which is the evidence that they were duplicative rather than additive. |
| Rule 5 (no surface holds its own intent classifier) | process rule; no mechanism |
| Rule 6 (read surfaces delegate to `OperatorSnapshot`) | process rule; no mechanism. `OperatorSnapshot` is the de-facto read model today, but nothing prevents a new surface from bypassing it. |

**What was verified before deleting, and why the list is stated rather than summarised.** Two audits in this repo have already proposed deletions on a "no callers" claim that was wrong — `SignalBroadcaster` was nearly removed while `real_time_signal_evaluator.rb:330` called it unguarded. Producers were checked alongside consumers here:

- `market_analysis_service.rb` (1159 LOC) was *not* chat-only and is retained. `operator_snapshot.rb:247` calls `MarketAnalysisService.new(symbol:).technical_indicators`, and `OperatorSnapshot` feeds the CLI, the MCP server, and the positions table. An earlier audit counted it as chat weight; that was wrong.
- `chat_memory_service.rb` (166 LOC) is retained. `chat_message.rb:45` uses `ChatMemoryService::TRADING_KEYWORDS_REGEX` in `#trading_related?`, so it is not an orphan. Its inbound edge is now a single constant reference from a model, which is a thin reason to keep a service alive — a later cleanup should move the regex to `ChatMessage` and retire the service, but that is a change to model code and does not belong in a deletion.
- `ChatSession` and `ChatMessage` are retained. They hold persisted rows and `bin/futuresbot status` still counts active sessions. Deleting a surface is not a licence to drop its data.
- `slack_notification_service.rb` holds no reference to `SlackCommandHandler` in either direction; the two shared no helpers.

**Environment variables that are now unused.** `SLACK_SIGNING_SECRET` and `SLACK_AUTHORIZED_USERS` existed only to authorize inbound Slack requests and have no remaining reader. They were made fail-closed in PR #512, five days before the endpoint they guarded was removed — a small illustration of the cost this ADR is about: work spent hardening a surface that a duplication audit was about to delete. `SLACK_BOT_TOKEN` and the channel variables are **not** dead and must not be removed; outbound alerts depend on them.

## Consequences

- **~3,130 LOC of application code leave**, of which 2,031 are the six files named above; the remainder is the chat view (421), `ChatAuditLogger` (250), `chat_bot.rake` (216), and the CLI REPL and its helpers (~214). With specs and docs the diff is ~6,860 deletions. The suite goes from 3,120 examples to 2,911 on the standard sweep, 0 failures either side; no behaviour outside the deleted surfaces changes.
- **Remote control of trading state is now: the web positions UI, or nothing.** MCP, CLI, and TUI are all local-process surfaces. That is a deliberate narrowing and it makes ADR 0005's "if MCP is ever exposed over a network socket" caveat the single most likely way this ADR gets violated.
- **The operator loses `/bot-status` in Slack.** Slack becomes push-only. This is a real ergonomic loss and is accepted: the read it served is available from `bin/futuresbot status`, from MCP, and from the alerts Slack still sends unprompted.
- **`docs/slack-integration.md` and `docs/chat-bot-interface.md` document surfaces that no longer exist.** They are updated in this change. The `wiki/` tree (`Architecture.md`, `Services-Guide.md`, `Getting-Started.md`, `API-Reference.md`, `Testing-Guide.md`) also references them and is a separate repository — it is stale until updated there.
- **The six-serializer problem is reduced, not solved.** The CLI, TUI, web UI, and MCP still each format positions. What changed is that four surfaces formatting one read model is a presentation concern, whereas eight surfaces each computing their own was a correctness one.
- **ADR 0005's rule 2 now has teeth it did not have.** Before this change, "a new mutating surface requires an ADR" was written in a document whose own table listed six mutating surfaces that arrived without one. Removing two of them makes the rule describe the codebase instead of contradicting it.
