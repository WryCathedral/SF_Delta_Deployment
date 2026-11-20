# Salesforce Delta Pipeline

`SfOrgValidateDeploy` validates or deploys a Salesforce metadata delta. Install extension **1.0.6** (publisher `GouravPragvamsaPwC`) from the `vsix` folder. The task name in YAML is `SfOrgValidateDeploy@1`.

How to install it in Azure DevOps, store the JWT key, and create the pipeline: [Set up the pipeline in Azure DevOps](docs/azure-devops-setup.md).

The pipeline that sets every input is [pipelines/example-azure-pipelines.yml](pipelines/example-azure-pipelines.yml). Repository: [Salesforce Delta Pipeline](https://github.com/WryCathedral/SF_Delta_Deployment).

## What the task does

1. Fetches full git history when the checkout is shallow, so `HEAD~1` exists.
2. Installs the latest stable Salesforce CLI unless you pin a version or skip installation.
3. Installs `sfdx-git-delta`, and installs Code Analyzer when that option is on for a validation run.
4. Downloads the JWT or Auth URL secure file selected on the task.
5. Builds the delta between `deltaFromRef` and `deltaToRef` (default `HEAD~1`..`HEAD`).
6. On validation only, optionally scans the delta with Code Analyzer.
7. Validates (`--dry-run`) or deploys `package/package.xml`, including destructive changes when the delta produced them.
8. Publishes the delta package and Code Analyzer report even when validation, deployment, or the scan fails.
9. Writes a one-sentence status banner after each step. Validation and deployment each report succeeded, failed, or canceled, and list rejected components.

`operationMode: auto` validates when a pull request **targets** `targetBranch`, and deploys when a non-PR build runs on that same branch. Other branches are skipped. Code Analyzer does not run on deploy. A task cannot add pipeline stages or jobs.

## Set up a pipeline

1. Install **1.0.6** in **Organization settings → Extensions**.
2. Create a variable group, for example `QA-Org`, with `alias`, `client_id`, and `username`.
3. Upload the unencrypted PEM private key, or an Auth URL file, under **Pipelines → Library → Secure files**, and authorize the pipeline to use it.
4. Add the YAML from [pipelines/example-azure-pipelines.yml](pipelines/example-azure-pipelines.yml). Set `targetBranch`, the variable group, and `jwtKeySecureFile` to your secure file name.
5. Set the job timeout higher than `deployWaitTime` (default 120 minutes). The example uses 180 minutes.

Use `ubuntu-latest` or `windows-latest`. Both include PowerShell 7. For JWT, `orgType: sandbox` logs in at `https://test.salesforce.com` and `orgType: production` logs in at `https://login.salesforce.com`, unless `instance_url` is set.

For an Auth URL, set `authMethod: authUrl` and `sfdxAuthUrlSecureFile` to the secure file name. Leave the JWT inputs unused.

## Inputs

Required for the default JWT pipeline: `operationMode`, `alias`, `authMethod`, `orgType`, `client_id`, `username`, `jwtKeySecureFile` (or an existing key path), `targetBranch`, `validateTestLevel`, and `deployTestLevel`.

| Input | Required | Default | What you enter |
|---|---|---|---|
| `operationMode` | Yes | `auto` | `auto`, `validate`, or `deploy`. |
| `alias` | Yes | `$(alias)` | Salesforce CLI org alias used after login and as `--target-org`. |
| `authMethod` | Yes | `jwt` | `jwt` or `authUrl`. |
| `orgType` | Yes for JWT | `sandbox` | `sandbox` or `production`. Selects the login host when `instance_url` is blank. |
| `client_id` | Yes for JWT | `$(client_id)` | Connected app consumer key. |
| `username` | Yes for JWT | `$(username)` | Salesforce username for the JWT user. |
| `instance_url` | No | empty | Optional `--instance-url`, such as a My Domain URL. |
| `jwtKeySecureFile` | Yes for JWT unless a path is set | empty | Secure file from **Pipelines → Library → Secure files**. The task downloads that file id. |
| `jwt_key_file` | No | empty | Path when a previous step already downloaded the key. |
| `jwt_token_path` | No | empty | If this path exists, it is used instead of the secure file. |
| `sfdxAuthUrlSecureFile` | One Auth URL source when `authMethod` is `authUrl` | empty | Secure file containing one `force://...` line. |
| `sfdx_auth_url_file` | No | empty | Path to an Auth URL file. |
| `sfdx_auth_url` | No | empty | Auth URL secret. Used when no Auth URL file is set. Prefer a secure file. |
| `sfCliVersion` | No | empty | Blank installs `@salesforce/cli@latest`. Set a version only to pin one. |
| `skipInstallSfCli` | No | `false` | Skip CLI install when `sf` is already on the agent. |
| `deltaFromRef` | No | `HEAD~1` | Git ref for `sfdx-git-delta --from`. |
| `deltaToRef` | No | `HEAD` | Git ref for `--to`. |
| `ignoreFile` | No | empty | Optional ignore file. When blank, `ignorefile` or `.sgdignore` in the repo root is used if present. |
| `targetBranch` | Yes for `auto` | `develop` | Branch that pull requests validate against and that post-merge builds deploy. |
| `validateTestLevel` | Yes | `NoTestRun` | `NoTestRun`, `RunRelevantTests`, `RunLocalTests`, `RunAllTestsInOrg`, or `RunSpecifiedTests`. |
| `validateSpecifiedTests` | When validate level is `RunSpecifiedTests` | empty | Comma-separated Apex test class names. |
| `deployTestLevel` | Yes | `NoTestRun` | Same five values as the validate level. |
| `deploySpecifiedTests` | When deploy level is `RunSpecifiedTests` | empty | Comma-separated Apex test class names. |
| `codeCoveragePercent` | No | empty, which means 75 | Whole number from 0 to 100. Every Apex class in the test run must meet it. Skipped for `NoTestRun`. |
| `deployWaitTime` | No | `120` | Minutes passed to `sf project deploy start --wait`. |
| `ignoreWarnings` | No | `false` | Add `--ignore-warnings` on validate and deploy. |
| `ignoreConflicts` | No | `true` | Add `--ignore-conflicts` on deploy only. |
| `runCodeAnalyzer` | No | `false` | Scan delta sources during validation. |
| `useCustomPmdRuleset` | No | `false` | Use a PMD ruleset instead of the default rule selector. |
| `pmdRulesetPath` | When custom PMD is on | empty | Path to the PMD ruleset XML. |
| `codeAnalyzerRuleSelector` | No | `all` | `--rule-selector` when custom PMD is off. |
| `codeAnalyzerSeverityThreshold` | No | `2` | `--severity-threshold` for the scan. |
| `enforceSeverityGate` | No | `true` | Fail when any finding severity is greater than `maxAllowedSeverity`. |
| `maxAllowedSeverity` | No | `2` | Highest numeric severity that still passes. |
| `publishDeltaArtifact` | No | `true` | Publish the delta package even when the org operation fails. |
| `deltaArtifactName` | No | `Delta-Package` | Artifact name. The example uses `$(Build.DefinitionName)-Delta-Package`. |
| `publishCodeAnalyzerArtifact` | No | `false` | Publish the scan report even when the scan fails. |
| `codeAnalyzerArtifactName` | No | `sf-code-analyzer` | Artifact name. The example uses `$(Build.DefinitionName)-Code-Analyzer`. |

Field-level help is also on the task in the pipeline editor. The setup guide explains secure-file permissions, checkout credentials, job timeout, and the JWT connected app.
