# teez-registry

Catalog for teez packages installable through the [rqp-plugin-teez](https://github.com/Coditary/teez-cli/tree/main/packaging/rqp-plugin-teez) ReqPack plugin.

## Files

| File | Purpose |
|------|---------|
| `packages.json` | teez CLI and runner plugin catalog |
| `teez-cli-index.json` | Pinned ReqPack index for the teez CLI |
| `plugins/vitest/` | Vitest runner plugin for ReqPack `plugin` installs |

## Usage

```bash
rqp install ./path/to/rqp-plugin-teez
rqp install teez teez-cli
rqp install teez vitest
```

Sync content from the teez dev workspace `registry/` folder when publishing updates.
