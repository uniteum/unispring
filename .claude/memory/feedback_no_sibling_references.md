---
name: Don't reference sibling contracts
description: contracts/interfaces shouldn't name other contracts unless they actually depend on them
type: feedback
---

A contract or interface's NatSpec should not mention other contracts unless that contract must know about them (i.e. imports them or its public surface references them). Lower-level pieces in particular should never name their callers — Fountain shouldn't mention Unispring or Mimicry; IPlacer shouldn't name "factories like Mimicry" as the reason it exists.

**Why:** keeps dependency direction clean and prevents docs from rotting when sibling contracts are renamed/added/removed. The interface's purpose can be stated in its own terms.

**How to apply:** when writing or editing NatSpec, check that every contract name mentioned corresponds to something the file imports or otherwise has to know about. "Matches X" / "as in X" / "callers like X" callouts to siblings are the usual offenders — drop them or rephrase generically.
