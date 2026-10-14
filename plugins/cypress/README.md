# teez cypress runner plugin

Cypress adapter for teez. Discovers projects with `cypress.config.*` or a `cypress/` spec tree and runs tests via `npx cypress`.

## Install via ReqPack

```bash
rqp install teez cypress
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `npx cypress`
- Spec reporter output parsing with stable test ids (`spec.cy.js > suite > test`)
- Pass, fail, skip, todo, and duration extraction from Mocha spec output
- Coverage via `teez run . --with-coverage` when `@cypress/code-coverage` is configured in the project
- Runner overrides from `teez.config.lua`

## Project override

```lua
return {
    runners = {
        cypress = {
            pattern = "login",
            reporter = "spec",
            args = { "--browser", "chrome" },
            coverage = {
                reports_directory = "coverage",
                report = "coverage/lcov.info",
            },
        },
    },
}
```

## Notes

- `teez list` tries `cypress run --dry-run` first. Current Cypress releases do not support `--dry-run`, so teez falls back to scanning `cypress/**/*.cy.{js,ts,jsx,tsx}` spec files for `describe` / `it` blocks.
- `teez run` uses `npx cypress run --reporter spec` (override with `runners.cypress.reporter`). Test ids use the spec basename from Cypress `Running:` output (for example `sample.cy.js > suite > test`).
- Coverage is not built into Cypress itself. The plugin runs with `--env coverage=true` and expects `@cypress/code-coverage` plus Istanbul instrumentation in the application under test. Without that setup, `teez run . --with-coverage` still runs tests but may not produce `coverage/lcov.info`.
- `cypress info` only reports installed browsers and Cypress version; it does not list specs or tests.
