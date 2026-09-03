# Domain Docs

How engineering skills should consume this repository's domain documentation when exploring or changing the codebase.

## Before exploring, read these

- Read `CONTEXT.md` at the repository root for the product's domain language.
- Read the ADRs in `docs/adr/` that affect the area being considered.
- If one of these files does not exist, proceed silently rather than suggesting that it be created upfront.

## File structure

This is a single-context repository:

```text
/
├── CONTEXT.md
├── docs/
│   ├── adr/
│   └── agents/
└── src/
```

## Use the glossary's vocabulary

When output names a domain concept in an issue, proposal, hypothesis, or test, use the term defined in `CONTEXT.md`. Do not drift to synonyms that the glossary explicitly says to avoid.

If a required concept is absent from the glossary, reconsider whether the proposed language belongs to the project or note the gap for later domain clarification.

## Flag ADR conflicts

If proposed work contradicts an existing ADR, surface the conflict explicitly rather than silently overriding the decision. Identify the relevant ADR and explain why it may need to be revisited.
