# teez-registry

Catalog for teez packages installable through the [rqp-plugin-teez](https://github.com/Coditary/teez-cli/tree/main/packaging/rqp-plugin-teez) ReqPack plugin.

## Files

| File | Purpose |
|------|---------|
| `packages.json` | teez CLI and runner plugin catalog |
| `teez-cli-index.json` | Pinned ReqPack index for the teez CLI |
| `plugins/*/` | Runner plugins for ReqPack `plugin` installs |

## Available runner plugins

| ID | Description |
|----|-------------|
| `vitest` | Vitest (Vite) |
| `jest` | Jest |
| `node-test` | Node.js built-in test runner |
| `mocha` | Mocha |
| `ava` | AVA |
| `bun` | Bun test |
| `deno` | Deno test |
| `playwright` | Playwright E2E |
| `cypress` | Cypress E2E |
| `webdriverio` | WebdriverIO E2E |

## Usage

```bash
rqp install ./path/to/rqp-plugin-teez
rqp install teez teez-cli
rqp install teez vitest
rqp install teez jest
# … any plugin id from the table above
```

Sync content from the teez dev workspace `registry/` folder when publishing updates.
