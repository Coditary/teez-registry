# teez jest runner plugin

Jest adapter for teez. Discovers projects with `jest.config.*` or a `jest` key in `package.json` and runs tests via `npx jest`.

## Install via ReqPack

```bash
rqp install teez jest
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `npx jest`
- Verbose output parsing with stable test ids (`file > suite > test`)
- Pass, fail, skip, and duration extraction from Jest default verbose reporter
- Coverage via `teez run . --with-coverage` (`coverage/lcov.info`)
- Runner overrides from `teez.config.lua`

## Project override

```lua
return {
    runners = {
        jest = {
            pattern = "unit",
            args = { "--runInBand" },
            coverage = {
                reports_directory = "coverage",
                report = "coverage/lcov.info",
            },
        },
    },
}
```

## Notes

- `teez list` prefers `jest --json --passWithNoTests` for full test ids and falls back to `jest --listTests` (file paths only).
- `teez run` uses `jest --verbose` so nested suite output is parsed into `file > suite > test` ids.
- Jest skipped tests are reported with the `○` symbol and mapped to `skip`.
