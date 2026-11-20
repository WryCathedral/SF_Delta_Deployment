# Salesforce Delta Pipeline

`SfOrgValidateDeploy` needs the inputs below. Each other input has a default and can be left unchanged.

## Always

| Input | Default | What you enter |
|---|---|---|
| `operationMode` | `auto` | `auto` validates when a pull request targets **Target branch**, and deploys when a non-PR build runs on that same branch. `validate` is always a dry-run. `deploy` is always a deploy. |
| `alias` | `$(alias)` | Salesforce CLI org alias used after login and as `--target-org`. |
| `authMethod` | `jwt` | `jwt` for a connected app and private key. `authUrl` for an SFDX Auth URL. |
| `validateTestLevel` | `NoTestRun` | Apex tests for the dry-run: `NoTestRun`, `RunLocalTests`, `RunAllTestsInOrg`, or `RunSpecifiedTests`. |
| `deployTestLevel` | `NoTestRun` | Apex tests for the deploy. Same four values as the validate level. |

## JWT authentication

Shown when `authMethod` is `jwt`.

| Input | Default | What you enter |
|---|---|---|
| `orgType` | `sandbox` | `sandbox` uses `https://test.salesforce.com`. `production` uses `https://login.salesforce.com`. |
| `client_id` | `$(client_id)` | Connected app consumer key. |
| `username` | `$(username)` | Salesforce username for the JWT user. |
| `jwt_key_file` | `$(jwt_key_file)` | Full path on the agent to the JWT private key. After Download Secure File, use `$(jwtkey.secureFilePath)`. |

## SFDX Auth URL

Shown when `authMethod` is `authUrl`. Provide one of these. The task fails when both are empty. A file path is used first.

| Input | What you enter |
|---|---|
| `sfdx_auth_url_file` | Path to a file that contains one `force://...` URL. A relative path is resolved from the repository root. |
| `sfdx_auth_url` | The Auth URL itself, usually a secret variable. Used only when the file path is empty. |

## Required only for the option you turn on

| Input | When it is required | What you enter |
|---|---|---|
| `validateSpecifiedTests` | `validateTestLevel` is `RunSpecifiedTests` | Apex test class names for validation, separated by commas, semicolons, or spaces. |
| `deploySpecifiedTests` | `deployTestLevel` is `RunSpecifiedTests` | Apex test class names for deployment, separated the same way. |
| `pmdRulesetPath` | Code Analyzer is on and **Use custom PMD ruleset** is on | Path to your PMD ruleset `.xml` in the repo or on the agent. |

## Set up a pipeline

1. Install this extension in the Azure DevOps organization: **Organization settings → Extensions**.
2. Create a variable group, for example `QA-Org`, with `alias`, `client_id`, and `username`. Mark the secret values as secret.
3. For JWT, upload the private key under **Pipelines → Library → Secure files**.
4. Create a YAML pipeline on the Salesforce repo. Set `trigger` and `pr` to the same integration branch you pass as `targetBranch`.
5. Run `SfOrgValidateDeploy@1` and select the secure file on the task. The task downloads that file and fetches git history when the checkout is shallow.

With `operationMode: auto`, a pull request into that branch validates, and the build on that branch after merge deploys.

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
      validateTestLevel: NoTestRun
      deployTestLevel: NoTestRun
```

Replace `main` with your integration branch in the trigger, the PR filter, and `targetBranch`. Use `orgType: production` for a production org.

For an SFDX Auth URL instead of JWT, upload a secure file that contains one `force://...` line and set `authMethod: authUrl` and `sfdxAuthUrlSecureFile` to that file name.
