@AGENTS.md

## Plan files

- Plans are stored in `./plans/` (configured via `.claude/settings.json` `plansDirectory`)
- **Naming schema**: `yyyy-mm-dd_name-of-the-plan.md`
  - Date: ISO format `yyyy-mm-dd` (date the plan was created)
  - Separator: underscore `_` between date and name
  - Name: lowercase, hyphens as word separators, alphanumeric only
  - Extension: `.md`
  - Regex: `^[0-9]{4}-[0-9]{2}-[0-9]{2}_[a-z0-9][a-z0-9-]*\.md$`
  - Example: `2026-02-26_dual-audio-wav-hooks.md`
- **Implemented plans** go into `./plans/done/` (same naming schema applies)
- A **pre-commit hook** (`.githooks/pre-commit`) enforces this schema in both `plans/` and `plans/done/` and rejects non-conforming filenames
- Git hooks directory is set to `.githooks/` via `core.hooksPath` (run `git config core.hooksPath .githooks` after cloning)
