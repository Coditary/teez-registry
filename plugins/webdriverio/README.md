# teez webdriverio runner plugin

WebdriverIO adapter for teez. Discovers projects with `wdio.conf.*` and runs E2E tests via `npx wdio run`.

## Install via ReqPack

```bash
rqp install teez webdriverio
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `npx wdio run <config>`
- `--reporters spec` for streaming pass/fail/skip symbols (`✓`, `✖`, `-`, `?`)
- Stable test ids: `path/to/spec.js > suite > test`
- `list` tries `wdio run --spec none --mochaOpts.dryRun` first, then falls back to include globs
- Coverage via `teez run . --with-coverage` (best-effort `nyc`/`c8` wrapper)
- Runner overrides from `teez.config.lua`

## Project override

```lua
return {
    runners = {
        webdriverio = {
            config = "wdio.conf.ts",
            pattern = "login",
            args = { "--headless" },
            coverage = {
                tool = "nyc",
                reports_directory = "coverage",
                report = "coverage/lcov.info",
            },
        },
    },
}
```

## Coverage

WebdriverIO does not emit LCOV coverage on its own. `build_coverage_run` wraps `wdio run` with `nyc` or `c8` when configured. For browser E2E coverage, instrument application code and add a WDIO coverage service (for example `wdio-coverage-service` or `@wdio/monocart-service`) so `coverage/lcov.info` exists before using `teez run --with-coverage`.

## Notes

- `teez list` calls the plugin `list()` function, which runs `npx wdio run <config> --spec none --mochaOpts.dryRun` and parses spec-reporter output; when dry-run is unavailable it lists spec files from include globs.
- Override the reporter with `runners.webdriverio.args = { "--reporters", "dot" }`; `parse_line` targets the default `spec` reporter.
- Mocha `grep` filters map to `--mochaOpts.grep` via `runners.webdriverio.pattern`.
