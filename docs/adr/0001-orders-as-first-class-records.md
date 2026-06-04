# ADR 0001: Orders as First-Class Records

**Date:** 2026-06-04
**Status:** Accepted

## Context

The bot opens and closes Positions by placing orders on the Coinbase API. Currently, orders are ephemeral — the API call is made, and the Position model records the resulting entry or exit price. No order record is stored.

The Position model answers "what exposure do we have?" but cannot answer:
- Did the fill price match the Signal's target price, or was there slippage?
- What happened to an order placed during a network outage — was it filled, partially filled, or rejected?
- Why did a Position open at a price different from what the Strategy intended?

## Decision

Orders are a first-class domain concept. Every order placed on Coinbase will be stored as an `Order` record, associated with the Position it opens or closes. The Order captures the intended price, the actual fill price, quantity, order type, and exchange order ID.

## Consequences

- Slippage is auditable: compare `Order#target_price` with `Order#fill_price`.
- Outage recovery is possible: on restart, the bot can query Coinbase for pending order status and reconcile against stored records.
- Position entry/exit prices become derivable from Orders rather than stored independently — the Position is the net result of its Orders.
- Adds an `Order` model and migration; existing Positions have no associated Orders and represent a data gap pre-adoption.
