# AGENTS.md

## Skills Involved

- caveman skill
- karparthy-guidelines skill

## Project Structure

```
bootstrap
├── cilium
│   └── values.yaml
├── kind
│   └── config.yaml
└── test-app
    ├── namespace.yaml
    └── nginx.yaml
Makefile
docs/DESIGN.md
docs/PROGRESS.md
```

## PLAN

Read `docs/DESIGN.md` before starting any work. It contains the overall strategy, goals, and task breakdown for this project. Understanding the plan is crucial for effective progress tracking and decision-making.

## Progress Tracking

Always keep `docs/PROGRESS.md` up to date throughout every session.

### When to update docs/PROGRESS.md

Update it **immediately** after any of the following:

- Completing a task or subtask
- Making a meaningful code change (new feature, refactor, bug fix)
- Hitting a blocker or discovering an issue
- Changing direction or approach
- Finishing a session (end-of-session summary)

### What to include

**Current Status** — one-line summary of where things stand right now.

**What was just done** — concrete description of the most recent work completed. Be specific: filenames, function names, decisions made.

**What's next** — the immediate next step(s), ordered by priority.

**Blockers** — anything preventing progress. If none, say so explicitly.

**Open questions** — unresolved decisions or unknowns that need attention.

### Format

Keep entries in reverse-chronological order (newest at the top). Each entry should have a timestamp and a short heading.

```markdown
## YYYY-MM-DD — <short heading>

**Status:** <one-liner>

**Done:**
- ...

**Next:**
- ...

**Blockers:** None / <description>

**Open questions:**
- ...
```

### Rules

- Never skip an update because the change "seems small." Small changes compound.
- If docs/PROGRESS.md doesn't exist yet, create it before starting any work.
- Write for a future Claude instance that has no memory of this session — be explicit, not terse.
- Do not delete old entries; the history is valuable.
