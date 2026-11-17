---
name: nc-harness-check
description: Checks whether the shared skills of nc-harness reach this runtime. Use when someone says "nc-harness-check" or asks whether the harness skills are loaded.
---

# nc-harness-check

Test skill from `nc-harness`. It does one thing only: answer with a fixed line that shows this skill was loaded and which harness version applies.

1. Run `nc version`. The output has the form `nc-harness <commit> <mode>`.
2. Answer with exactly this one line and nothing else:

   `NC-HARNESS-CHECK Crane-7 · Skill nc-harness-check · Harness <commit> · <mode>`

   `<commit>` and `<mode>` come from the output of step 1.
3. If `nc version` fails, use `unknown` for commit and mode and append ` · nc missing`.

Change nothing, install nothing, run no other commands.
