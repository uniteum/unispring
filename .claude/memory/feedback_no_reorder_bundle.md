---
name: feedback-no-reorder-bundle
description: "Don't bundle function reordering / structural rearrangement with substantive code changes — user wants those as separate diffs for side-by-side comparison"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8f707ee7-c546-4811-b2a0-9fed6be86cc3
---

Never bundle pure rearrangement (function reordering by visibility, moving blocks of code, large stylistic resequencing) with substantive changes (caching, comments, NatSpec additions, logic edits) in the same diff.

**Why:** User reviews changes by reading the diff side-by-side. Reordering produces large add/delete spans that hide the substantive edits, making the diff illegible. After bundling Cyfrin-style function reordering with three small changes (peg cache, security-contact NatSpec, suppression comment) on Reflector.sol, user reverted the entire change and asked for the non-reordering edits only.

**How to apply:** When applying a set of recommendations that includes reordering, do the substantive edits in one pass and offer the reordering as a separate follow-up. Same applies to renames-through-the-file, mass docstring reformatting, etc. — anything where the diff noise from rearrangement would swamp the real change.
