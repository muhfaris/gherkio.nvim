# Changelog

## v0.1.1 (2026-07-23)

### Bug Fixes

- **parser**: Fixed `get_steps_in_section` incorrectly matching nested list items as steps. Now tracks section-level indentation so only top-level steps are detected.
- **results**: Fixed `prettify_json` continuation line prefix alignment when a line lacks a key prefix.

## v0.1.0 (2026-07-06)

Initial release of `gherkio.nvim` — a lightweight, zero-dependency Neovim plugin for the [Gherkio](https://github.com/muhfaris/gherkio) API testing engine.

### Features

- **Async test execution** — Runs in the background via `vim.system`/`jobstart`. Editor stays responsive.
- **Run modes** — Single step under cursor, active section (setup/steps/teardown), full scenario, or up to a step boundary.
- **Multi-scenario & directory runs** — Execute all `.yaml` tests in a directory or across the whole project.
- **Dry-run preview** — `:Gherkio run all --dry-run` to see expanded requests without HTTP calls.
- **Live progress** — Real-time "Executing step 2/5…" updates.
- **Inline gutter signs** — `✔` / `✗` per step in the sign column after a run.
- **Assertion-level quickfix** — Failed assertions jump to the exact line, not the step header.
- **Flexible results layout** — Float, vertical split, or horizontal split. Request/response payloads auto-fold.
- **Smart JSON wrapping** — Long response values wrap with proper indentation.
- **Copy as cURL** — Convert any step to cURL, copy to clipboard, show in syntax-highlighted preview.
- **Preview request** — Inspect expanded cURL without copying (`<leader>gi`).
- **Paste from cURL** — Convert clipboard cURL into Gherkio DSL YAML at cursor.
- **Cascading env/account selectors** — Auto-detect configs, interactive menus via `vim.ui.select`.
- **`:Gherkio` command** — Single entry point with full tab-completion.
- **Buffer-local keymaps** — Auto-bound on YAML files in Gherkio projects. Fully configurable.
- **YAML JSON Schema** — Auto-registers test schema with `yamlls` for validation and autocompletion.
- **`:checkhealth gherkio`** — Validates binary, project root, environments, and config.
- **Zero external dependencies** — Pure Lua. No rocks, no Python, no Node.

Commits: `912d3d2` → `2d50e04` (17 commits)
