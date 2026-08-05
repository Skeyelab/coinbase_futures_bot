# ATR Chandelier exit: backtest verdict

**Date:** 2026-08-04
**Verdict:** DO NOT ENABLE in the bot. Keep the infrastructure.

## What was tested

The operator's current n8n rule (`CB Watcher - Multi Position`), ported as a pure
policy and given engine parity:

```
stop = max(fixed_stop, peak_net_pnl - trail_atr x ATR x contract_size x contracts)
```

ratcheting upward only, and only once the position has been in profit.

## Result: worse than baseline at every parameter, on both symbols

**BIP** — 3 months, real fees (10 bps + $0.15/contract)

| config | trades | net/trade | win% |
|---|---|---|---|
| baseline (strategy tp/sl) | 138 | **-3.51** | 39.9 |
| chandelier 4.0x / -75 | 88 | -4.05 | 25.0 |
| chandelier 1.5x / -75 | 334 | -4.94 | 22.2 |
| chandelier 2.5x / -75 | 166 | -5.25 | 22.9 |
| chandelier 2.5x / -30 | 166 | -5.33 | 22.9 |

**NOL** — 6 weeks, real fees (9 bps + $0.85/contract)

| config | trades | net/trade | win% |
|---|---|---|---|
| baseline | 57 | **-27.61** | 38.6 |
| chandelier 4.0x / -75 | 23 | -42.72 | 17.4 |
| chandelier 2.5x / -30 | 52 | -35.55 | 3.8 |
| chandelier 1.5x / -75 | 39 | -37.72 | 7.7 |
| chandelier 2.5x / -75 | 27 | -43.56 | 7.4 |

## Why

The win rate collapses: **39.9% -> 22.9% on BIP, 38.6% -> 7.4% on NOL**. The trail
systematically converts winners into smaller winners or losers.

The parameter sweep says the same thing: the WIDER the trail, the LESS damage
(4.0x is the best chandelier on both symbols), and the tighter floor (-30) is
worse than -75 on both. A rule whose optimum is "turn it off" is not underfit --
it is pure cost.

This is the same conclusion the trailing-giveback backtest reached on 2026-07-30,
for the same structural reason recorded then: **the n8n rules were standalone
discretionary systems with no competing take-profit. Layered onto a strategy that
already has a working tp, they replace a good exit with a worse one.** Two
independent ports, two identical verdicts.

## The bigger finding underneath it

**The baseline loses money on both symbols.** No exit rule fixes a negative gross
edge. See ADR 0008: the measured 13.9 bps gross edge is net negative against
Coinbase's real 20.35 bps round trip, and the exit debate is rearranging
furniture in a strategy the venue has already beaten.

## What this does NOT say

It measured the chandelier against the bot's **technical multi-timeframe
entries**. Positions placed by hand on a macro view have no competing
take-profit -- which is the configuration the n8n rule was designed for. Nothing
here refutes it for that use, and it remains live in n8n for hand-placed trades.

## What was kept

- `Signals::Indicators.atr` -- the codebase had NO ATR at all. Wilder true range
  with a SIMPLE MEAN, matching the n8n populator rather than the textbook
  Wilder smoothing, pinned by a parity spec against a live reading.
- `Backtest::AtrSeries` -- 1h ATR sampled on the 5m stepping clock, with the
  lookahead guard (a bar's ATR is not readable until it closes).
- `Trading::AtrChandelierExit` -- inert unless explicitly configured.
- Engine parity, with the peak taken from the favorable extreme and the fill
  from the adverse one.

42 examples, 28 mutations killed.
