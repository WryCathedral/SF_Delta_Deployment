# SF Delta Deployment — Azure DevOps extension

Custom Azure Pipelines task **`SfOrgValidateDeploy`** (*Salesforce org: validate & deploy(delta)*).

## Repo layout (extension packaging)

| Path | Purpose |
|------|---------|
| `vss-extension.json` | Extension manifest (set your `publisher` id) |
| `overview.md` | Marketplace / extension details page |
| `images/extension-icon.png` | Extension icon |
| `buildAndReleaseTasks/SfOrgValidateDeploy/task.json` | Task UI inputs |
| `buildAndReleaseTasks/SfOrgValidateDeploy/sf-delta.ps1` | Task implementation |
| `pipelines/example-azure-pipelines.yml` | Sample pipeline after install |
| `package.json` | `npm run package` → builds the `.vsix` |
| `scripts/write-icon.ps1` | Helper to regenerate a placeholder icon |

## Build the VSIX (no Marketplace required)

1. Set `"publisher"` in `vss-extension.json` to your [Marketplace publisher id](https://marketplace.visualstudio.com/manage).
2. From this repo root:

```bash
npm install
npm run package
```

Or: `npx tfx-cli extension create --manifest-globs vss-extension.json`

3. Upload the generated `.vsix` in Azure DevOps: **Organization settings → Extensions → Shared**.
4. In a pipeline use:

```yaml
- task: SfOrgValidateDeploy@1
```

See `pipelines/example-azure-pipelines.yml` for a full example (`fetchDepth: 0` is required for `HEAD~1` delta).
