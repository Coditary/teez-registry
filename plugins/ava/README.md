# teez ava runner plugin

AVA adapter for teez. Discovers projects with `ava.config.*` or `ava` in `package.json` `devDependencies`, and runs tests via `npx ava`.

## Install via ReqPack

```bash
rqp install teez ava
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `npx ava`
- Verbose output parsing with stable test ids (`file > suite > test`)
- Pass, fail, skip, and duration extraction from AVA verbose reporter
- Coverage via `teez run . --with-coverage` using `c8 ava` (`coverage/lcov.info`)
- Runner overrides from `teez.config.lua`

## Project override

```lua
return {
    runners = {
        ava = {
            pattern = "unit",
            args = { "--serial" },
            coverage = {
                reports_directory = "coverage",
                report = "coverage/lcov.info",
            },
        },
    },
}
```

## Notes

- `teez list` prefers `ava --verbose --dry-run` for full test ids and falls back to manifest include globs (file paths only).
- `teez run` uses `ava --verbose` and maps AVA `›` titles to `file > suite > test` ids.
- Skipped tests are reported with `- [skip]` and mapped to `skip`.
- Coverage uses `npx c8 --reporter=lcov ava`; requires `c8` in the project for coverage runs.
