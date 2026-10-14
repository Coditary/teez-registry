# teez mocha runner plugin

Mocha adapter for teez. Discovers projects with `.mocharc.*`, a `mocha` key in `package.json`, or `mocha` in `devDependencies`, and runs tests via `npx mocha`.

## Install via ReqPack

```bash
rqp install teez mocha
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `npx mocha`
- Spec reporter parsing with stable test ids (`file > suite > test`)
- Pass, fail, skip, and numbered failure extraction from Mocha spec output
- Coverage via `teez run . --with-coverage` using `nyc mocha` or `c8 mocha` (`coverage/lcov.info`)
- Runner overrides from `teez.config.lua`

## Project override

```lua
return {
    runners = {
        mocha = {
            pattern = "unit",
            args = { "--recursive" },
            coverage = {
                tool = "c8",
                reports_directory = "coverage",
                report = "coverage/lcov.info",
            },
        },
    },
}
```

## Notes

- `teez list` prefers `mocha --dry-run --reporter json` for full test ids and falls back to manifest include globs (file paths only).
- `teez run` uses `mocha --reporter spec` and tracks nested suite headers for ids.
- Coverage defaults to `npx nyc --reporter=lcov mocha`; set `coverage.tool = "c8"` for `c8` instead.
- Requires `nyc` or `c8` (and `@istanbuljs/nyc-config` / coverage presets as needed) in the project for coverage runs.
