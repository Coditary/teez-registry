# teez node-test runner plugin

Node.js built-in test runner (`node --test`) adapter for teez. Discovers projects with `**/*.test.{js,mjs,cjs}`, `package.json` entries mentioning `node --test` or `node:test` (via `json_anchors` when teez supports them), or an optional `.node-test` marker file.

## Install via ReqPack

```bash
rqp install teez node-test
```

Installs manifest + Lua into `~/.local/share/teez/plugins/`.

## Features

- `run` / `list` via `node --test`
- Spec reporter parsing with stable test ids (`file > suite > test`)
- Pass, fail, skip, todo, and duration extraction from the spec reporter
- Coverage via `teez run . --with-coverage` using `--experimental-test-coverage` and the built-in `lcov` reporter
- Runner overrides from `teez.config.lua`

## CLI commands

| teez action | Node command |
|-------------|--------------|
| `teez run` | `node --test --test-reporter=spec <targets…>` |
| `teez list` | `node --test --test-reporter=tap <target>` per discovered file (Node has no `--list`; TAP output is parsed instead) |
| `teez run --with-coverage` | `node --test --experimental-test-coverage --test-reporter=spec --test-reporter=lcov --test-reporter-destination=stdout --test-reporter-destination=coverage/lcov.info <targets…>` |

## Project override

```lua
return {
    runners = {
        ["node-test"] = {
            pattern = "unit",
            args = { "--test-timeout=30000" },
            coverage = {
                reports_directory = "coverage",
                report = "coverage/lcov.info",
                include = "src/**",
                exclude = "**/*.test.js",
            },
        },
    },
}
```

Use `command` to override the executable (same pattern as vitest):

```lua
runners = {
    ["node-test"] = {
        command = "/usr/bin/node",
    },
}
```

When `command` is set, the plugin does not prepend `--test`; include runner flags in `args` instead.

## Notes

- Discovery uses `json_anchors` on `package.json`, `**/*.test.{js,mjs,cjs}`, or `.node-test`. Vitest/Jest projects with higher-priority plugins still win when their config anchors match.
- `teez list` executes tests once with the TAP reporter because Node.js does not provide a collect-only mode. Skipped tests appear in TAP/list output; todo tests are reported when present.
- Coverage requires Node.js with `--experimental-test-coverage` and the built-in `lcov` reporter (Node 20.11+). TypeScript/source-map coverage may be incomplete until Node maps coverage back to original sources.
- Test ids include the relative file path so results align between `teez list` and `teez run`.
