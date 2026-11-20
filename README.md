# Salesforce Delta Pipeline

`SfOrgValidateDeploy` validates or deploys a Salesforce metadata delta. Install extension **1.0.2** from the `vsix` folder. The repository link in the task is [Salesforce Delta Pipeline](https://github.com/WryCathedral/SF_Delta_Deployment).

## What the task does

1. Fetches full git history when the checkout is shallow, so `HEAD~1` exists.
2. Installs the latest stable Salesforce CLI unless you pin a version or skip installation.
3. Installs `sfdx-git-delta`, and installs Code Analyzer when that option is on for a validation run.
4. Downloads the JWT or Auth URL secure file selected on the task.
5. Builds the delta, optionally scans it, then validates or deploys.
6. Publishes the delta package and Code Analyzer report even when validation, deployment, or the scan fails.
7. Writes a one-sentence status banner after each step. Validation and deployment each report succeeded, failed, or canceled, and list rejected components.

`operationMode: auto` validates when a pull request targets **Target branch**, and deploys when a non-PR build runs on that same branch.

## Inputs

| Input | Default | What you enter |
|---|---|---|
| `operationMode` | `auto` | `auto`, `validate`, or `deploy`. |
| `alias` | `$(alias)` | Salesforce CLI org alias used after login and as `--target-org`. |
| `authMethod` | `jwt` | `jwt` or `authUrl`. |
| `validateTestLevel` | `NoTestRun` | `NoTestRun`, `RunRelevantTests`, `RunLocalTests`, `RunAllTestsInOrg`, or `RunSpecifiedTests`. |
| `deployTestLevel` | `NoTestRun` | Same five values as the validate level. |
| `codeCoveragePercent` | blank, which means 75 | Whole number from 0 to 100. Every Apex class in the test run must meet it. Blank uses 75%. Skipped for `NoTestRun`. |
| `orgType` | `sandbox` | `sandbox` uses `https://test.salesforce.com`. `production` uses `https://login.salesforce.com`. |
| `client_id` | `$(client_id)` | Connected app consumer key. Shown for JWT. |
| `username` | `$(username)` | Salesforce username for the JWT user. |
| `jwtKeySecureFile` | | Secure file name from **Pipelines → Library → Secure files**. The task downloads it. |
| `jwt_key_file` | | Optional path when a previous step already downloaded the key. |
| `sfdxAuthUrlSecureFile` | | Secure file containing one `force://...` line. Shown for Auth URL. |
| `sfdx_auth_url_file` | | Optional path to an Auth URL file. |
| `sfdx_auth_url` | | Auth URL secret. Used when no Auth URL file is set. |
| `sfCliVersion` | blank | Blank installs `@salesforce/cli@latest`. Set a version only to pin one. |
| `targetBranch` | `develop` | Branch that pull requests validate against and that post-merge builds deploy. |
| `validateSpecifiedTests` | | Required when validate level is `RunSpecifiedTests`. |
| `deploySpecifiedTests` | | Required when deploy level is `RunSpecifiedTests`. |
| `pmdRulesetPath` | | Required when Code Analyzer and **Use custom PMD ruleset** are on. |
| `publishDeltaArtifact` | `true` | Publishes `Delta-Package` even when the org operation fails. |
| `publishCodeAnalyzerArtifact` | `false` | Publishes `Code-Analyzer` even when the scan fails. |

## Set up a pipeline

1. Install **1.0.2** in **Organization settings → Extensions**. If 1.0.2 is already installed, remove it and install this package again. Azure DevOps will not replace files while the version number stays 1.0.2.
2. Create a variable group, for example `QA-Org`, with `alias`, `client_id`, and `username`.
3. Upload the JWT private key, or an Auth URL file, under **Pipelines → Library → Secure files**.
4. Add `SfOrgValidateDeploy@1` and select that secure file on the task.

```yaml
trigger:
  branches:
    include:
      - main

pr:
  branches:
    include:
      - main

variables:
  - group: QA-Org

pool:
  vmImage: ubuntu-latest

steps:
  - checkout: self

  - task: SfOrgValidateDeploy@1
    displayName: Salesforce Org Validate & Deploy (Delta)
    inputs:
      operationMode: auto
      alias: $(alias)
      authMethod: jwt
      orgType: sandbox
      client_id: $(client_id)
      username: $(username)
      jwtKeySecureFile: your-jwt-private-key.pem
      targetBranch: main
      validateTestLevel: RunLocalTests
      deployTestLevel: RunLocalTests
      codeCoveragePercent: '85'
```

Replace `main` with your integration branch. Leave `codeCoveragePercent` empty to require 75% on every class. Use `orgType: production` for a production org.

For an Auth URL, set `authMethod: authUrl` and `sfdxAuthUrlSecureFile` to the secure file name.

A task cannot add pipeline stages or jobs. Put those in the YAML around this one task.
