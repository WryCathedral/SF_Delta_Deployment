# sf-delta-ado-extension

Azure DevOps **custom task** `SfOrgValidateDeploy` (**Salesforce org: validate & deploy(delta)**): JWT or SFDX Auth URL login, sfdx-git-delta (`HEAD` vs `HEAD~1`), optional Code Analyzer on **delta only** (default rules or custom PMD ruleset), and pipeline artifacts. Delta validate/deploy failures **fail the task**.

## Quick start

1. Edit `vss-extension.json`: set `publisher` to your publisher ID. Keep `1.0.0` until you publish; bump the version only when updating an already-installed extension.
2. Create the package: `npm install -g tfx-cli` then `tfx extension create --manifest-globs vss-extension.json`.
3. Install the generated `.vsix` in your Azure DevOps organization.
4. Install the extension in the organization, then in YAML use the **short task name** (same as other Marketplace tasks):

```yaml
- task: SfOrgValidateDeploy@1
```

Full form `YourPublisher.sf-delta-pipeline-extension.SfOrgValidateDeploy@1` is optional and only needed if another extension has the same task name. See `pipelines/example-azure-pipelines.yml`.

## Authentication

Pick **`authMethod`**:

| Method | Inputs shown |
|--------|----------------|
| `jwt` | `orgType` (sandbox/production), `client_id`, `username`, optional `instance_url` override, `jwt_key_file` (optional `jwt_token_path`) |
| `authUrl` | `sfdx_auth_url_file` and/or secret `sfdx_auth_url` |

Uses `sf org login jwt` or `sf org login sfdx-url`.

## Code Analyzer (optional checkbox)

When **`runCodeAnalyzer`** is on:

- **`useCustomPmdRuleset` = false** → default `sf code-analyzer run --rule-selector` (default `all`).
- **`useCustomPmdRuleset` = true** → provide **`pmdRulesetPath`** (PMD ruleset `.xml` in the repo or on the agent). The task generates a Code Analyzer config with that custom ruleset and runs against **delta** sources only.

## Other inputs

| Input | Purpose |
|--------|--------|
| `operationMode` | `auto` / `validate` / `deploy` |
| `targetBranch` | Integration branch for Auto PR validate / post-merge deploy |
| `orgType` | JWT only: `sandbox` or `production` (sets login host if `instance_url` blank) |
| `validateTestLevel` / `deployTestLevel` | Separate Apex test levels for validate vs deploy |
| `validateSpecifiedTests` / `deploySpecifiedTests` | Test classes when level is `RunSpecifiedTests` |
| `deployWaitTime` | Minutes for `--wait` (default `120`) |
| `ignoreWarnings` | Pass `--ignore-warnings` |
| `ignoreConflicts` | Pass `--ignore-conflicts` on deploy only (default on) |
| `alias` | Org alias after login |
| `publishDeltaArtifact` / `deltaArtifactName` | Delta package artifact |

## Multiple orgs

One pipeline (or variable group) per org; the task is environment-agnostic.

## Checkout

Use `fetchDepth: 0` so `git` can resolve `HEAD~1`.
