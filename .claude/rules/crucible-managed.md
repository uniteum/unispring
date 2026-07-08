---
paths:
  - "foundry.toml"
  - ".mcp.json"
  - ".vscode/settings.json"
  - ".claude/settings.json"
  - ".claude/rules/always.md"
  - ".claude/rules/comments.md"
  - ".claude/rules/crucible-tests.md"
  - ".claude/rules/deployment.md"
  - ".claude/rules/lint.md"
  - ".claude/rules/solidity.md"
  - ".claude/rules/submodule.md"
  - ".claude/rules/crucible-managed.md"
  - ".claude/skills/bitsify/SKILL.md"
  - ".claude/skills/predict/SKILL.md"
  - ".claude/skills/smelt/SKILL.md"
  - ".claude/skills/smelt/smelt.sh"
---

# Crucible-Managed Files — Edit the Source, Not the Copy

The file you are about to change is **owned by the crucible submodule**.
`smelt.sh` copies it from `lib/crucible/<same path>` into this repo, and
**every smelt run overwrites the copy in place**. Editing the copy here
silently loses the change the next time anyone smelts.

## First: where are you?

Run `git rev-parse --show-toplevel` if unsure.

- **Repo root ends in `/crucible`** — you are in the crucible submodule
  itself. This file *is* the source. Edit it here, commit on a real
  branch (see `submodule.md`), done.

- **Any other repo (the file sits beside a `lib/crucible/`)** — this is
  a copy. Do **not** edit it. Edit the source instead.

## Editing the source from a consumer repo

1. Edit `lib/crucible/<same path as this file>`.
2. `cd lib/crucible`, ensure you are on a real branch (not detached —
   see `submodule.md`), commit the change there.
3. `cd` back to the consumer root and re-run smelt to refresh the copy:
   `bash lib/crucible/.claude/skills/smelt/smelt.sh` (or `/smelt`).
4. Stage the refreshed copy **and** the bumped submodule pointer in the
   consumer repo.

A change that only touches the consumer copy is a bug, not a fix — it
will not reach other repos and it will be erased on the next smelt.

## Adding or removing a managed file

The authoritative list is the `FILES` array in
`.claude/skills/smelt/smelt.sh`. When that list changes, update this
rule's `paths:` frontmatter and the **Files** table in the crucible
`README.md` to match.
