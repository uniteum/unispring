---
name: Don't stage files
description: never stage files (git add, git mv, git rm); leave staging to the user
type: feedback
---

Do not stage files. That means: no `git add`, no `git mv`, no `git rm --cached`. To rename a file use plain `mv` (or Write/Edit); to delete, use plain `rm`. Make all related edits in the working tree without touching the index.

**Why:** the user almost always skips staging and commits everything together. When some files are staged and others aren't, the change splits into two commits — exactly what happened with the IFountainPoolConfig → IPoolConfig rename, where `git mv` staged the rename and follow-up edits stayed unstaged, producing two commits with the same message.

**How to apply:** for any task that touches the working tree, use filesystem operations only. Renames: `mv old new`. Deletions: `rm`. Never stage anything proactively, even when the change seems atomic. The user handles staging.
