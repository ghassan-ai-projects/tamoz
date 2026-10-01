---
name: skill-authoring
description: Turn a verified piece of work into a reusable Agent Skill (a SKILL.md directory) that meets Tamoz's authoring bar. Use when asked to create, draft or write a skill from a session, a trajectory or a procedure.
license: MIT
allowed-tools: read_file list_directory search_text create_file apply_patch
metadata:
  version: "1.0.0"
  tamoz.risk: guarded
---

# Skill authoring

You write a skill: instructions another agent will follow later, on a different task of the
same kind. You draft it; a person reviews and installs it. You never install or approve it.

## Input

`trajectory.md` in the workspace describes one verified piece of work: the task, the plan, the
tools used in order, the files changed, the checks that passed, and the final answer.

## Output

One directory, named exactly as the task says (it already exists, with an empty `references/`),
holding `SKILL.md` and, only when needed, `references/*.md`. Nothing else in the workspace changes.

## Procedure

1. **Find the reusable part.** Separate what would repeat on the next task of this kind (the
   order of steps, what evidence to gather first, how to verify) from what was specific to this
   one (file names, values, the customer). Only the reusable part goes in the skill.
2. **Write the frontmatter.** `name` equals the directory name: lowercase letters, digits and
   single hyphens. `description` is at most 320 bytes and says what the skill does, then when to
   use it, starting that clause with "Use when". Set `metadata.tamoz.risk` to `read_only`,
   `guarded` or `elevated` — an honest label; it grants nothing.
3. **Write the body.** Aim for under 150 lines: when to use it (and look-alikes that are not),
   the procedure as numbered steps, how to verify the result, and rules that must hold. Name
   the tools by what they do, not by one agent's tool names.
4. **Move detail out.** Long checklists, schemas or examples go in `references/<topic>.md`,
   and the body must mention every such file by its path.
5. **Check it.** Re-read `SKILL.md` against steps 2–4. Every path the body mentions must exist,
   and every file you created must be mentioned.

## Rules

- Never copy secrets, credentials, personal data or customer names from the trajectory.
- A skill grants no permission. Never write that a tool is pre-approved or that a check can be
  skipped.
- Do not invent steps the trajectory did not show to work; say what was verified.
