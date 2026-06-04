# Charm Ruby TUI Rewrite — Design

**Date:** 2026-06-04  
**Status:** Approved  
**Scope:** Phase 1 (this doc) + Phase 2 (NTCharts, tracked separately)

## Goal

Replace the hand-rolled ANSI TUI (`lib/cli/tui_dashboard.rb`, ~620 lines) with a full rewrite using [Charm Ruby](https://charm-ruby.dev/). Motivations: the existing `render` method is 130+ lines of string concatenation, `with_cooked_stdin` forms are fragile, and there is no component model for extending the UI.

Phase 1 delivers: Bubbletea Elm architecture, Lipgloss styling, Huh? forms, scrollable Bubbles::Table panels, and hybrid real-time data (PostgreSQL LISTEN/NOTIFY for positions/signals, 1s polling for prices).

## Architecture

Elm architecture — every state change flows through `Model → Update → View`.

```
lib/tui/
  app.rb                # Model struct, Init, entry point
  update.rb             # Update — all message handlers
  view.rb               # View — Lipgloss layout + Bubbles tables
  messages/
    tick.rb             # 1s price-poll tick
    db_notify.rb        # PG NOTIFY (positions, signals)
  components/
    status_bar.rb       # Lipgloss-styled status row
    positions_table.rb  # Bubbles::Table, scrollable
    signals_table.rb    # Bubbles::Table, scrollable
    prices_panel.rb     # Lipgloss-styled price rows
  forms/
    close_position.rb   # Huh? Input + Confirm
    reconcile.rb        # Huh? Confirm
    halt_toggle.rb      # Huh? Confirm + optional Input
```

## Data Sources

Two message streams feed the same `Update` function:

- **`Tick` (1s poll)** — queries `RecentMarketPrice` / `Tick` table → updates `model.prices`
- **`DbNotify` (PG LISTEN/NOTIFY)** — instant push when positions or signals change → updates `model.positions` or `model.signals`
- **Keypresses** — update UI state or push a Huh? form onto `model.active_form`

### PostgreSQL triggers (new migration)

```sql
AFTER INSERT OR UPDATE ON positions       → NOTIFY 'positions'
AFTER INSERT OR UPDATE ON signal_alerts   → NOTIFY 'signal_alerts'
```

### Startup sequence

1. `App.init` opens a dedicated `PG::Connection`, issues `LISTEN positions` + `LISTEN signal_alerts`
2. Spawns two background threads: PG notify listener + 1s price ticker
3. Both push messages into a thread-safe queue; Bubbletea's event loop drains it
4. Initial data load fires immediately on startup

## Components

### Positions & Signals — Bubbles::Table

Scrollable tables with `↑/↓`. No row limit (replaces 15/10 hard cap). Lipgloss handles colour (green/red side, confidence colouring).

### Status bar — Lipgloss

Day/swing counts, signals, Coinbase connection, halt status, eval age. Independent re-render.

### Prices panel — Lipgloss

Futures and spot split retained. Age indicator: green ≤15s, yellow stale.

### Forms — Huh?

Overlay model: `active_form` slot on the model. Dashboard renders underneath dimmed. On submit or cancel, `active_form` clears and a flash appears.

| Form | Components |
|---|---|
| Close Position | `Huh::Input` (position ID) → `Huh::Confirm` |
| Reconcile | `Huh::Confirm` |
| Halt / Resume | `Huh::Confirm` → optional `Huh::Input` (reason) |

### Key bindings

All existing bindings preserved: `q r p s i c o h ↑↓←→ +/-`. `KEY_ACTIONS` map moves into `update.rb`.

## Data Flow

```
1s Tick        → query prices      → model.prices updated   → re-render prices panel
PG NOTIFY pos  → query positions   → model.positions updated → re-render positions table
PG NOTIFY sigs → query signals     → model.signals updated   → re-render signals table
Keypress       → Update dispatches → model state change      → re-render affected component
```

Only changed panels re-render — no full-screen clear on every tick.

## Error Handling

| Failure | Behaviour |
|---|---|
| DB query error | Flash `:error`; stale data stays visible |
| PG NOTIFY connection lost | Auto-reconnect with exponential backoff; status bar shows `NOTIFY: reconnecting…` |
| Price poll timeout | Age indicator goes yellow/red; no crash |
| Form service call fails | Flash `:error`; form dismisses cleanly |
| Terminal resize (WINCH) | Bubbletea handles natively |

No silent failures — every error path produces a visible flash or status indicator.

## Testing

`Update` is a pure function — testable without a TTY:

```ruby
model = Tui::App.init
model, _cmd = Tui::Update.call(model, Tui::Messages::DbNotify.new(:positions))
expect(model.positions).to eq(Position.open.to_a)
```

- **Unit** — `Update` and component `View` in isolation; no TTY required
- **Integration** — full init + message sequence against test DB
- **Cleanup** — `spec/lib/cli/tui_dashboard_spec.rb` deleted when old class is removed

## Cutover

`lib/cli/tui_dashboard.rb` stays in place until `lib/tui/app.rb` is feature-complete. `bin/futuresbot dashboard` switches entry point. Old class + specs deleted on cutover.

## Out of Scope (Phase 2)

NTCharts price sparklines — last 60 ticks per Underlying as a sparkline panel. No architecture changes needed; slots in as a new component in `view.rb`. Tracked in a separate issue.
