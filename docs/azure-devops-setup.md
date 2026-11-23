# Set up the Salesforce Delta Pipeline in Azure DevOps

This guide installs **Salesforce Delta Pipeline** `1.0.7` and wires `SfOrgValidateDeploy@1` into an Azure DevOps YAML pipeline. The task builds a metadata delta with `sfdx-git-delta` (`HEAD~1` to `HEAD` by default), logs in with JWT or an SFDX Auth URL, then validates or deploys that delta.

The annotated pipeline with every task input is [`pipelines/example-azure-pipelines.yml`](../pipelines/example-azure-pipelines.yml).

## What you need before the pipeline

- An Azure DevOps project with Pipelines enabled.
- A Salesforce DX repository that contains `sfdx-project.json` and source-format metadata. The task deploys `package/package.xml` generated in the repository root.
- Permission to install an organization extension, create a variable group, and upload a secure file.
- A Salesforce integration user that can deploy to the target org.
- For JWT: a connected app and an **unencrypted RSA private key** in PEM format. The file must contain `BEGIN RSA PRIVATE KEY` or `BEGIN PRIVATE KEY`. Do not upload the `.pub` file, a certificate, or a passphrase-protected key.
- An agent image that includes PowerShell 7 (`pwsh`), Node.js, npm, and Git. `ubuntu-latest` and `windows-latest` already include these. A self-hosted agent must have `pwsh` on `PATH`.

`operationMode: auto` does two different things in one pipeline:

| Build | What the task runs |
|---|---|
| Pull request whose **target** branch is **Target branch** | Validation (`sf project deploy start --dry-run`) |
| Non-PR build running **on** that same branch | Deployment |
| Any other branch, or a PR aimed at a different branch | Nothing. The task exits successfully. |

Code Analyzer, when enabled, runs only on validation and only on the delta sources.

## 1. Install the extension

1. In Azure DevOps, open **Organization settings → Extensions**.
2. Install **Salesforce Delta Pipeline** version **1.0.7** (publisher `GouravPragvamsaPwC`, extension id `sf-delta-pipeline-extension`).
3. If you are installing from a file, upload `vsix/GouravPragvamsaPwC.sf-delta-pipeline-extension-1.0.7.vsix` and share it with the organization.
4. Confirm the task **Salesforce Org Validate & Deploy (Delta)** appears when you edit a pipeline. The YAML name is `SfOrgValidateDeploy@1`.

The task does not create stages or jobs. Put those in the YAML around this one task.

## 2. Create the Salesforce login

Use JWT for a normal pipeline. Use an SFDX Auth URL only when you already have a `force://` URL and accept that it is a long-lived credential.

### JWT (recommended)

1. In the target org, create a connected app (External Client App) with OAuth enabled.
2. Enable the scopes the integration user needs to deploy. `sf org login jwt` requires `refresh_token` and `api` (or `sfap_api`) at minimum, plus whatever the deploy itself needs.
3. Upload the certificate that matches the private key, and set the app to **Admin approved users are pre-authorized**.
4. Assign the integration user's profile or a permission set to that connected app.
5. Copy the **Consumer Key**. That value is `client_id`.
6. Copy the integration user's username. That value is `username`.
7. Keep the private key. You will upload it as a secure file in the next section. It must be an unencrypted PEM private key.

`orgType` selects the login host when **Instance URL** is blank:

| `orgType` | Login host |
|---|---|
| `sandbox` | `https://test.salesforce.com` |
| `production` | `https://login.salesforce.com` |

Set `instance_url` when the org uses a My Domain URL that should be passed to `sf org login jwt --instance-url`. Sandboxes still use `orgType: sandbox` unless you override the URL.

### SFDX Auth URL

1. On a machine that is already authorized to the org, run `sf org display --verbose --json` and copy the `sfdxAuthUrl` value. It starts with `force://`.
2. Put that single line in a text file, for example `qa-org-auth-url.txt`.
3. Upload that file as a secure file and set `authMethod: authUrl` and `sfdxAuthUrlSecureFile` to the file name.

You can bind the URL to the secret input `sfdx_auth_url` instead of a file. Prefer the secure file. `orgType`, `client_id`, `username`, and the JWT key inputs are not used in this mode.

## 3. Store variables and the key

### Variable group

1. Open **Pipelines → Library → + Variable group**.
2. Name it for the org, for example `QA-Org`.
3. Add these variables. Mark `client_id` as secret if the organization treats the consumer key as a secret.

| Variable | Used by | Example |
|---|---|---|
| `alias` | `alias` | `qa` |
| `client_id` | `client_id` | connected app consumer key |
| `username` | `username` | `integration@example.com.qa` |

4. Save the group. Under **Pipeline permissions**, authorize the pipeline that will use it. If you skip this, the first run stops until someone permits the pipeline.

Reference the group from YAML:

```yaml
variables:
  - group: QA-Org
```

### Secure file

1. Open **Pipelines → Library → Secure files → + Secure file**.
2. Upload the PEM private key, for example `your-jwt-private-key.pem`.
3. Open the file, then **Pipeline permissions**, and authorize the same pipeline.
4. Set `jwtKeySecureFile` to that file name. Azure DevOps passes the file id to the task, and the task downloads it. A separate **Download secure file** step is not required.

The task reads the job access token from `ENDPOINT_AUTH_PARAMETER_SYSTEMVSSCONNECTION_ACCESSTOKEN`, then from `SYSTEM_ACCESSTOKEN`. If the log says the agent did not provide a token or a download ticket:

- Re-select the secure file on the task and authorize the pipeline for that file.
- On the job, enable **Allow scripts to access the OAuth token** so `SYSTEM_ACCESSTOKEN` is present.

Do not commit the private key or the Auth URL into the repository.

## 4. Add the pipeline

1. In the Salesforce repository, commit a YAML file based on [`pipelines/example-azure-pipelines.yml`](../pipelines/example-azure-pipelines.yml). Replace `develop`, the variable group name, and `your-jwt-private-key.pem`.
2. In Azure DevOps, open **Pipelines → New pipeline**, select the repository, and choose **Existing Azure Pipelines YAML file**.
3. Point the pipeline at that YAML file and save it.
4. Authorize the variable group and the secure file if Azure DevOps prompts on the first run.

The example sets every input. Required values for the default JWT + `auto` path are:

| Input | Why it is required |
|---|---|
| `operationMode` | `auto`, `validate`, or `deploy`. |
| `alias` | Org alias passed to `--target-org`. |
| `authMethod` | `jwt` or `authUrl`. |
| `orgType` | Required for JWT. `sandbox` or `production`. |
| `client_id` | Connected app consumer key. Required for JWT. |
| `username` | JWT username. Required for JWT. |
| `jwtKeySecureFile` | Secure file name of the PEM private key. Required for JWT unless `jwt_token_path` or `jwt_key_file` already points at the key. |
| `targetBranch` | Branch that pull requests validate against and that post-merge builds deploy. Default `develop`. |
| `validateTestLevel` | Apex test level for validation. |
| `deployTestLevel` | Apex test level for deployment. |

Set these only for the mode that needs them:

| Input | When it is required |
|---|---|
| `sfdxAuthUrlSecureFile`, `sfdx_auth_url_file`, or `sfdx_auth_url` | One of them when `authMethod` is `authUrl`. |
| `validateSpecifiedTests` | When `validateTestLevel` is `RunSpecifiedTests`. Comma-separated Apex test class names. |
| `deploySpecifiedTests` | When `deployTestLevel` is `RunSpecifiedTests`. |
| `pmdRulesetPath` | When `runCodeAnalyzer` and `useCustomPmdRuleset` are both `true`. Path to a PMD ruleset XML file in the repo or on the agent. |

Recommended checkout, because the task runs `git fetch --unshallow` when `HEAD~1` is missing:

```yaml
- checkout: self
  persistCredentials: true
```

`persistCredentials` keeps the job token available for that fetch. Setting `fetchDepth: 0` also works and skips the unshallow step.

`deployWaitTime` defaults to `120` minutes and is passed to `sf project deploy start --wait`. Raise the **job** timeout above that value. The example uses `timeoutInMinutes: 180`. The Microsoft-hosted default job timeout is 60 minutes, which will cancel a deploy that is still waiting.

## 5. Inputs

Defaults match `buildAndReleaseTasks/SfOrgValidateDeploy/task.json` for extension `1.0.7`.

### Operation

| Input | Required | Default | Values |
|---|---|---|---|
| `operationMode` | Yes | `auto` | `auto`, `validate`, `deploy`. |
| `targetBranch` | Yes for `auto` | `develop` | Integration branch name, without `refs/heads/`. |

`validate` always dry-runs. `deploy` always deploys. `auto` uses the table at the top of this guide. A pull request is detected from `Build.Reason` / `System.PullRequest.PullRequestId`, and the PR target is `System.PullRequest.TargetBranch`.

### Authentication

| Input | Required | Default | What to enter |
|---|---|---|---|
| `alias` | Yes | `$(alias)` | Salesforce CLI alias used after login and as `--target-org`. |
| `authMethod` | Yes | `jwt` | `jwt` or `authUrl`. |
| `orgType` | Yes for JWT | `sandbox` | `sandbox` or `production`. Ignored when Instance URL is set. |
| `client_id` | Yes for JWT | `$(client_id)` | Connected app consumer key. |
| `username` | Yes for JWT | `$(username)` | Username of the JWT integration user. |
| `instance_url` | No | empty | Optional `--instance-url`. Example: `https://mydomain--qa.sandbox.my.salesforce.com`. |
| `jwtKeySecureFile` | Yes for JWT, unless a path is set | empty | Secure file name from **Pipelines → Library → Secure files**. |
| `jwt_key_file` | No | empty | Path used only when the secure file and `jwt_token_path` are not used. |
| `jwt_token_path` | No | empty | If this path exists, it is used instead of the secure file. |
| `sfdxAuthUrlSecureFile` | One Auth URL source when `authMethod` is `authUrl` | empty | Secure file containing one `force://...` line. |
| `sfdx_auth_url_file` | No | empty | Path to a file that already contains the Auth URL. |
| `sfdx_auth_url` | No | empty | Secret variable with the Auth URL. The task writes it to a temporary file. Prefer a secure file. |

JWT path order: an existing `jwt_token_path`, then `jwtKeySecureFile`, then `jwt_key_file`.

### Delta and CLI

| Input | Required | Default | What to enter |
|---|---|---|---|
| `sfCliVersion` | No | empty | Empty installs `@salesforce/cli@latest`. Set a version such as `2.161.0` to pin one. |
| `skipInstallSfCli` | No | `false` | `true` skips installation. `sf` must already be on `PATH`. |
| `deltaFromRef` | No | `HEAD~1` | Git ref passed to `sf sgd source delta --from`. |
| `deltaToRef` | No | `HEAD` | Git ref passed to `--to`. |
| `ignoreFile` | No | empty | Optional sfdx-git-delta ignore file. When blank, the task uses `ignorefile` or `.sgdignore` in the repo root if one of those files exists. |

The delta command writes `package/package.xml` and, when there are deletions, `destructiveChanges/destructiveChanges.xml`. Both `ignoredestructive` and `includedestructive` handling is enabled. The task copies those manifests into `artifacts/` before publish. If `package/package.xml` is missing after the delta, the task fails.

Right after the **Delta package generated.** banner the log prints the full contents of both files, under the headings `package/package.xml (components to add or update)` and `destructiveChanges/destructiveChanges.xml (components to delete)`. When the delta has no deletions, the log says `No destructiveChanges.xml was generated, so the delta has no deletions.` Use this output to confirm what the run is about to send to the org.

## Deleting flows

From Metadata API 44 onward, a destructive change that names a Flow by API name alone fails with `insufficient access rights on cross-reference id`. Every version has to be listed as `ApiName-N`. The task does this for you before every validation and deployment. There is no input to set.

For each `Flow` member in `destructiveChanges.xml` that has no `-N` suffix, the task:

1. Queries the target org with `sf data query --use-tooling-api` for every version of that flow. Names are sent in batches of 50.
2. Replaces the member with one entry per version found. `Account_Flow` becomes `Account_Flow-1`, `Account_Flow-2`, `Account_Flow-3`.
3. Leaves members that already end in `-N`, and every other metadata type, as they are.
4. Drops a flow that has no versions in the org. This keeps a re-run from failing after the delete already succeeded.

Example log output:

```text
##[section]Flow deletions: expanding Account_Flow to every version in qa
Flow deletions: Account_Flow-1, Account_Flow-2, Account_Flow-3
##[section]destructiveChanges/destructiveChanges.xml after Flow version expansion
```

What to expect:

- The expanded manifest is what `--post-destructive-changes` receives, and the delta artifact gets a copy named `destructiveChanges_flow-versions_<timestamp>.xml`. The original manifest stays in the artifact as `destructiveChanges_<timestamp>.xml`.
- If every deleted flow is already gone from the org and `package.xml` has no components either, the task logs `No components remain after Flow version expansion. Nothing to validate.` (or `deploy`) and finishes successfully without calling the org.
- If the Tooling API query fails, the task stops before deploying, reports `Flow version query failed`, and still publishes the delta artifact.
- The login user must be able to query `Flow` through the Tooling API. The query runs against the org that the pipeline logs in to, so validation and deployment each look at their own org.

This is the same approach as `version-flow-destructive.js` in the LSCCRM `.azure` folder, built into the task so no extra script or step is needed in the pipeline.

### Apex tests

| Input | Required | Default | Values |
|---|---|---|---|
| `validateTestLevel` | Yes | `NoTestRun` | `NoTestRun`, `RunRelevantTests`, `RunLocalTests`, `RunAllTestsInOrg`, `RunSpecifiedTests`. Used on validation. |
| `validateSpecifiedTests` | When validate level is `RunSpecifiedTests` | empty | Comma, semicolon, or whitespace separated Apex test class names. |
| `deployTestLevel` | Yes | `NoTestRun` | Same five values. Used on deployment. |
| `deploySpecifiedTests` | When deploy level is `RunSpecifiedTests` | empty | Same format as the validate list. |
| `codeCoveragePercent` | No | empty, which means 75 | Whole number from 0 to 100. Each Apex class in the test run must be at or above it. Skipped for `NoTestRun`. |

Production deploys that include Apex still have to satisfy Salesforce's own test-level rules. `NoTestRun` will be rejected by the org for those deploys. Use `RunLocalTests` or another level that runs tests when deploying Apex to production.

### Deploy options

| Input | Required | Default | What it does |
|---|---|---|---|
| `deployWaitTime` | No | `120` | Minutes passed to `--wait` on deploy start and deploy report. |
| `ignoreWarnings` | No | `false` | Adds `--ignore-warnings` on validate and deploy. |
| `ignoreConflicts` | No | `true` | Adds `--ignore-conflicts` on deploy only. Validation never ignores conflicts. |

### Code Analyzer

These inputs apply only when the resolved operation is **validate**. A post-merge deploy does not run the scan.

| Input | Required | Default | What it does |
|---|---|---|---|
| `runCodeAnalyzer` | No | `false` | Installs the `code-analyzer` plugin and scans delta sources under `changed-sources/force-app`. |
| `useCustomPmdRuleset` | No | `false` | Use a PMD ruleset XML file instead of `codeAnalyzerRuleSelector`. |
| `pmdRulesetPath` | When custom PMD is on | empty | Repo or agent path to the ruleset `.xml`. |
| `codeAnalyzerRuleSelector` | No | `all` | Passed to `--rule-selector` when custom PMD is off. |
| `codeAnalyzerSeverityThreshold` | No | `2` | Passed to `--severity-threshold`. |
| `enforceSeverityGate` | No | `true` | After the scan, fail the task if any CSV row has a numeric severity **greater than** `maxAllowedSeverity`. |
| `maxAllowedSeverity` | No | `2` | Highest severity number that still passes. |

The report is written to `reports/code-analyzer-report.csv`. If `changed-sources/force-app` is missing, the scan is skipped with a warning.

### Artifacts

| Input | Required | Default | What it does |
|---|---|---|---|
| `publishDeltaArtifact` | No | `true` | Publishes `artifacts/` even when validation, deployment, or the scan fails. |
| `deltaArtifactName` | No | `Delta-Package` | Pipeline artifact name. The example uses `$(Build.DefinitionName)-Delta-Package`. |
| `publishCodeAnalyzerArtifact` | No | `false` | Publishes `reports/` even when the scan fails. Only useful when Code Analyzer is enabled. |
| `codeAnalyzerArtifactName` | No | `sf-code-analyzer` | Pipeline artifact name. The example uses `$(Build.DefinitionName)-Code-Analyzer`. |

Published files are placed in the container folders `Delta-Package` and `Code-Analyzer`. The delta artifact holds `package_<timestamp>.xml`, `destructiveChanges_<timestamp>.xml` when there are deletions, and `destructiveChanges_flow-versions_<timestamp>.xml` when Flow deletions were expanded.

## 6. Run it

1. Open a pull request into the branch named by `targetBranch`. The task should log `mode=validate`, generate the delta, print `package.xml` and `destructiveChanges.xml`, and finish with `Validation succeeded.` or `Validation failed.`
2. Complete the pull request. The CI build on that branch should log `mode=deploy` and finish with `Deployment succeeded.` or `Deployment failed.`
3. Open the run's **Summary** and confirm the delta artifact. When the scan is published, the Code Analyzer artifact is there too.
4. On a branch that is not the target, `auto` logs a skip message and the task succeeds without logging in.

Rejected components are listed in the log as `##[error]` lines from the deploy report. Coverage below `codeCoveragePercent` (or 75 when that input is blank) fails the task after a successful deploy status, except when the test level is `NoTestRun`.

## Troubleshooting

| Log message | What to change |
|---|---|
| PowerShell was not found on this agent | Use `ubuntu-latest` or `windows-latest`, or install PowerShell 7 and put `pwsh` on `PATH`. |
| Could not download JWT private key / no download ticket | Authorize the secure file for this pipeline, re-select `jwtKeySecureFile`, and allow the job to access the OAuth token. |
| The JWT file is an OpenSSH public key / not a private key / encrypted | Upload the unencrypted RSA **private** key in PEM format. |
| `client_id` or `username` is required | Add them to the variable group and reference `$(client_id)` and `$(username)`. |
| Git could not resolve `HEAD~1` | Set `persistCredentials: true` on checkout, or set `fetchDepth: 0`. Confirm the branch has more than one commit. |
| `package/package.xml` not found after delta | The range produced no package the plugin could write. Confirm `sfdx-project.json` and that the commits contain metadata changes. |
| RunSpecifiedTests was selected but no test class names were provided | Set `validateSpecifiedTests` or `deploySpecifiedTests`. |
| PMD ruleset file not found | Set `pmdRulesetPath` to a file that exists in the checkout. |
| `Flow version query failed` | The Tooling API query for flow versions failed. Check that the org login worked, the user can query `Flow` through the Tooling API, and the alias points at the right org. The log above the error shows the CLI output. |
| `insufficient access rights on cross-reference id` on a Flow delete | The deployment ran a delete that was not versioned. Confirm extension 1.0.7 or later is installed and that the log shows `Flow deletions: ...` lines. |
| `No components remain after Flow version expansion` | Not an error. Every deleted flow is already gone from the org and there is nothing else to send. |
| Job canceled around 60 minutes | Increase `timeoutInMinutes` so it is greater than `deployWaitTime`. |
| Coverage is below the required percent | Raise test coverage, or set `codeCoveragePercent` to the threshold you actually want. `NoTestRun` skips this check. |
