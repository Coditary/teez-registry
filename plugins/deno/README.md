# teez deno runner plugin

Deno built-in test runner (`deno test`) adapter for teez. Discovers projects with `deno.json` / `deno.jsonc` or `**/*_test.ts` / `**/*.test.ts` files, and runs tests via `deno test`.

## Install via ReqPack

```bash
rqp install teez deno
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `deno test`
- Pretty reporter parsing with stable test ids (`file > suite > test`)
- Pass, fail, skip, and duration extraction from Deno test output
- Coverage via `teez run . --with-coverage` when Deno supports `--coverage` (`coverage/lcov.info`)
- Runner overrides from `teez.config.lua`

## CLI commands

| teez action | Deno command |
|-------------|--------------|
| `teez run` | `deno test <targets…>` |
| `teez list` | `deno test --list <targets…>` when Deno advertises `--list`; otherwise `deno test --reporter=tap` per target (TAP output is parsed) |
| `teez run --with-coverage` | `deno test --coverage=coverage <targets…>` |

## Project override

```lua
return {
    runners = {
        deno = {
            pattern = "unit",
            args = { "--parallel" },
            coverage = {
                reports_directory = "coverage",
                report = "coverage/lcov.info",
            },
        },
    },
}
```

Use `command` to override the executable (same pattern as vitest):

```lua
runners = {
    deno = {
        command = "/usr/bin/deno",
    },
}
```

When `command` is set, the plugin does not prepend `test`; include runner flags in `args` instead.

## Notes

- `teez list` prefers `deno test --list` when the installed Deno CLI exposes the flag; current stable Deno does not, so listing falls back to TAP reporter output (tests are executed once to collect names).
- `teez run` tracks the current file from `running N tests from ./file.ts` and builds ids from Deno's `name ... ok|FAILED|ignored` result lines.
- Nested `t.step()` output is mapped to `file > parent > step` using the parent test's pending `...` header line.
- Requires the `deno` executable on `PATH` (`requires: ["deno"]` in the manifest).
- Priority `114` sits below Jest/Vitest and alongside Bun so framework-specific configs still win when their anchors match.
- Coverage collects raw profiles under `coverage/`; run `deno coverage --lcov --output=coverage/lcov.info coverage/` if your Deno version does not emit `lcov.info` automatically.
