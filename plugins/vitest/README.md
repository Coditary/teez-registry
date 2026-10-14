# teez vitest runner plugin

Vitest adapter for teez. Discovers projects with `vitest.config.*` or `vite.config.*` and runs tests via `npx vitest`.

## Install via ReqPack

```bash
rqp install teez vitest
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `npx vitest`
- Verbose output parsing with stable test ids (`file > suite > test`)
- Skip, todo, pass, fail, and duration extraction
- Coverage via `teez run . --with-coverage` (requires `@vitest/coverage-v8` or `@vitest/coverage-istanbul` in the project)
- Runner overrides from `teez.config.lua`

## Project override

```lua
return {
    runners = {
        vitest = {
            pattern = "unit",
            args = { "--pool=threads" },
            coverage = {
                reports_directory = "coverage",
                report = "coverage/lcov.info",
                provider = "v8",
            },
        },
    },
}
```

## Notes

- `teez list` follows Vitest's `list` command: skipped and todo tests are not listed (Vitest limitation).
- During `teez run`, Vitest prints skipped and todo tests with the same `↓` symbol; teez reports both as `skip`.
