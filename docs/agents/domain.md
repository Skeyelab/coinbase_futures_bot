# Domain Docs

**Layout:** single-context

## Files

- `CONTEXT.md` — domain language, bounded contexts, key concepts (create if missing)
- `docs/adr/` — architectural decision records (create if missing)

## Rules for agents

1. Read `CONTEXT.md` before any domain reasoning.
2. New ADRs go in `docs/adr/NNNN-<slug>.md`.
3. If `CONTEXT.md` missing, note it and proceed with codebase inference.
