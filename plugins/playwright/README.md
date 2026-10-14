# teez playwright runner plugin

Playwright Test adapter for teez. Discovers projects with `playwright.config.*` (or `@playwright/test` in `package.json` when teez supports `json_anchors`) and runs E2E tests via `npx playwright test`.

## Install via ReqPack

```bash
rqp install teez playwright
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `npx playwright test`
- `--reporter=list` for streaming pass/fail/skip symbols (`✓`, `✘`, `-`)
- Line reporter fallback parsing (`[n/m] …` passes, numbered `1) …` failures)
- Stable test ids: `path/to/spec.ts:line:col › title`
- Runner overrides from `teez.config.lua`

## Project override

```lua
return {
    runners = {
        playwright = {
            pattern = "login",
            args = { "--project=chromium" },
        },
    },
}
```

## Coverage

Playwright Test does not produce LCOV coverage on its own. `build_coverage_run` runs the suite with `--reporter=list` and `--reporter=json`; configure an external coverage tool (for example monocart-coverage or Istanbul via Babel) in `playwright.config` to emit `coverage/lcov.info` before using `teez run --with-coverage`.

## Notes

- `teez list` calls the plugin `list()` function, which runs `npx playwright test --list` and normalizes ids to project-relative paths.
- Playwright list output may omit the test directory prefix; teez normalizes ids to project-relative paths so `list` and `run` align.
- Override the reporter with `runners.playwright.args = { "--reporter=line" }`; `parse_line` supports both list and line reporter formats.
