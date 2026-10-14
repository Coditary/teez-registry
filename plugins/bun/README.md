# teez bun runner plugin

Bun test runner adapter for teez. Discovers projects with `bunfig.toml`, `**/*.{test,spec}.{js,ts}` files, or optional `bun` in `package.json` `devDependencies`, and runs tests via `bun test`.

## Install via ReqPack

```bash
rqp install teez bun
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `bun test`
- Console output parsing with stable test ids (`file > suite > test`)
- Pass, fail, skip, todo, and duration extraction from Bun test output
- Coverage via `teez run . --with-coverage` when Bun supports `--coverage` (`coverage/lcov.info`)
- Runner overrides from `teez.config.lua`

## Project override

```lua
return {
    runners = {
        bun = {
            pattern = "unit",
            args = { "--timeout", "10000" },
            coverage = {
                reports_directory = "coverage",
                report = "coverage/lcov.info",
            },
        },
    },
}
```

## Notes

- `teez list` tries `bun test --dry-run` when Bun advertises the flag in `bun test --help`; otherwise it falls back to manifest include globs (file paths only).
- `teez run` tracks the current file header (`math.test.ts:`) and builds ids from Bun's `(pass|fail|skip|todo)` result lines.
- Requires the `bun` executable on `PATH` (`requires: ["bun"]` in the manifest).
- Priority `114` sits below Jest/Vitest so framework-specific configs still win when present.
