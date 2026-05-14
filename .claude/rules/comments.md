---
paths:
  - "**/*.sol"
  - "**/*.md"
---

# Comment Content

For what comments, natspec, and doc prose should *say*. Formatting
rules live in [solidity.md](./solidity.md); the default of writing
no comment at all lives in the global CLAUDE.md guidance.

These principles apply equally to Solidity natspec and to markdown
documentation. Examples below use Solidity natspec, but the same
rules guide README, DESIGN, and per-topic docs.

## Lead with purpose, not mechanics

The first sentence of a contract-, function-, or type-level natspec
— and the first paragraph of a markdown section — should answer
"what is this for?" in plain language. A reader who doesn't know the
project's metaphors should still learn what the thing does from that
opening alone. Mechanics come after, in `@dev` or further down the
section.

**Bad** (mechanics first, metaphor verbs, requires glossary):

```solidity
@notice Clone-per-hub factory that seats fair-launch pools on {placer}.
```

**Good** (says what it does for a caller):

```solidity
@notice Launches a hub token and any number of spokes against it,
        each in its own permanent single-sided pool.
```

## Plain verbs over metaphor verbs

Project-specific metaphors (seat, peg, neutrino, manifold, fountain,
lepton) can *name* concepts, but they shouldn't carry the verb of an
explanation. Reach for "hold", "lock", "open", "pair", "forward",
"mint" before "seat", "place", "found". The metaphor earns its keep
once the concept is introduced — but the first sentence should parse
to someone reading it cold.

## No noun pile-ups

Two or three domain terms stacked into one noun phrase parse as a
riddle. If a reader needs to know three project terms to parse one
phrase, restructure.

**Bad:** "seat every issue position funded through this Reflector"

**Good:** "holds the liquidity for each token issued through this
Reflector"

## Each detail at one level

- **Contract-level natspec** is orientation: what the contract is
  for, what it costs to use, when to reach for it. Read by someone
  scanning the file the first time.
- **Function-level natspec** is caller correctness: argument
  constraints, return semantics, side effects, ordering. Read by
  someone about to call.
- **Inline comments** are the *why* behind a single line, only when
  the why isn't obvious from the code.
- **Markdown docs** mirror the same hierarchy: README is for
  orientation, DESIGN for architecture, per-topic docs for the deep
  dive. Detail belongs where a reader needs it, not in every doc.

V4 tick math, sort-order quirks, flipped-currency genesis bootstraps,
and other caller-relevant nuance belong on the function that consumes
them — not on the contract header. A header that requires absorbing
V4 mechanics before the reader learns what the contract is for has
failed at orientation.

## Don't restate docs that live elsewhere

When README.md or DESIGN.md covers a pattern well — Bitsy factory,
trust boundaries, tick conventions, post-launch governance —
cross-reference it instead of restating it. "See README §Trust
boundaries" is preferred over a paragraph that re-explains trust
boundaries inline. Restated content drifts; cross-references stay
correct.

The same rule applies between contract- and function-level natspec:
don't describe `offer`'s tick translation in both the contract header
and the function header. Pick the level where a reader needs it.
