# Salesforce Delta Pipeline

This extension adds a single Azure Pipelines task **Salesforce org: validate & deploy(delta)** (`SfOrgValidateDeploy`) that:

- Computes metadata delta with **sfdx-git-delta** between `HEAD` and `HEAD~1` (configurable refs). Branch policy uses a single **target (integration) branch** setting: validate when a PR **targets** that branch; deploy when a build runs on that **same branch** after merge.
- Authenticates with **JWT** or **SFDX Auth URL** (pick list; only the selected method’s fields are shown).
- **Validate** path: optional **Code Analyzer** (checkbox) on **delta-generated sources only**. Default rule selector, or a **custom PMD ruleset** path when that option is checked. Optional CSV **severity gate**.
- Lets the user pick **separate Apex test levels** for validate vs deploy, **deploy wait time**, **ignore warnings / conflicts**, and (for JWT) **sandbox vs production** org type.
- Runs **dry-run deploy** of the delta package. If validation fails, the task **fails** (no full-metadata fallback).
- **Deploy** path: deploys the delta. If deployment fails, the task **fails** (no full-metadata fallback).
- Publishes **pipeline artifacts** for the delta package folder and Code Analyzer reports; artifact names are configurable for each pipeline.

## Branch policy and PR flow

1. **Pull request validation**: Set the task **Target branch** (for example `develop`) to match your policy branch. When a PR **targets** that branch, **Auto** runs **validate** (optional analyzer + delta dry-run).
2. **After merge**: The CI build on that **same branch** (not a PR build) triggers **deploy** for the merged commit.

Use a **checkout** step with `fetchDepth: 0` so `HEAD~1` resolves (avoid shallow clones with depth 1).

## What the task does

1. Decides whether this run is **validate**, **deploy**, or a skip. See **Operation**.
2. Confirms both git refs exist.
3. Installs Salesforce CLI unless **Skip Salesforce CLI install** is on, then installs the `sfdx-git-delta` plugin. On a validate run with Code Analyzer enabled, it also installs the `code-analyzer` plugin.
4. Logs in with JWT or an SFDX Auth URL and stores the org under **Org alias**.
5. Runs `sf sgd source delta` from **Delta from ref** to **Delta to ref**. Output is `package/package.xml`. Destructive changes, when the plugin writes them, are `destructiveChanges/destructiveChanges.xml` and are passed as `--post-destructive-changes`. The plugin is also given `--ignore-destructive ignoredestructive` and `--include-destructive includedestructive`.
6. Copies `package/package.xml` (and destructive changes, when present) into an `artifacts` folder.
7. On **validate** only, when **Run Code Analyzer on delta** is on: generates delta sources under `changed-sources/`, runs the analyzer, optionally fails on the severity gate, and optionally publishes the `reports` folder.
8. Runs a dry-run deploy (**validate**) or a real deploy (**deploy**). Both use the Apex test level, wait time, and warning setting for that path. **Ignore conflicts** is applied only on deploy.
9. When **Publish delta package as pipeline artifact** is on, publishes the `artifacts` folder after a successful run.

In **auto** mode the task reads these pipeline variables. You do not set them on the task:

| Pipeline variable | Use |
|---|---|
| `Build.Reason` | `PullRequest` selects the validate path. |
| `System.PullRequest.PullRequestId` | A value here also selects the validate path. |
| `System.PullRequest.TargetBranch` | Compared with **Target branch**. `refs/heads/` is stripped. Comparison ignores case. |
| `Build.SourceBranch` | On a non-PR build, compared with **Target branch** the same way. |
| `Build.SourcesDirectory` | Repository root. Relative paths on the task are resolved from here. |

## Operation

| Input | Required | Default | What it does |
|---|---|---|---|
| `operationMode` | Yes | `auto` | `auto`: a pull request that **targets** `targetBranch` runs **validate**. A non-PR build whose source branch **is** `targetBranch` runs **deploy**. Any other branch exits successfully and does no Salesforce work. `validate`: always dry-run. `deploy`: always deploy. |
| `targetBranch` | No | `develop` | Integration branch used only when `operationMode` is `auto`. |
| `alias` | Yes | `$(alias)` | Salesforce CLI org alias passed to login and to `--target-org` on validate and deploy. |

## Salesforce authentication

`authMethod` chooses which of the fields below the task form shows and which login command runs.

| Input | Required | Default | Shown when | What it does |
|---|---|---|---|---|
| `authMethod` | Yes | `jwt` | Always | `jwt` runs `sf org login jwt`. `authUrl` runs `sf org login sfdx-url`. |
| `orgType` | Yes | `sandbox` | `authMethod` = `jwt` | Used only when **Instance URL** is empty. `sandbox` uses `https://test.salesforce.com`. `production` uses `https://login.salesforce.com`. Any other value uses `https://test.salesforce.com`. |
| `client_id` | Yes | `$(client_id)` | `authMethod` = `jwt` | Connected app consumer key, passed as `--client-id`. The task fails when this is empty. |
| `username` | Yes | `$(username)` | `authMethod` = `jwt` | Salesforce username for the JWT user, passed as `--username`. The task fails when this is empty. |
| `instance_url` | No | empty | `authMethod` = `jwt` | When set, this exact value is `--instance-url` and `orgType` is not used to pick the host. Use it for a My Domain URL. |
| `jwt_key_file` | Yes | `$(jwt_key_file)` | `authMethod` = `jwt` | Full path on the agent to the JWT private key (`--jwt-key-file`). Typical value after Download Secure File: `$(jwtkey.secureFilePath)`. |
| `jwt_token_path` | No | empty | `authMethod` = `jwt` | When set, this path is the key file and `jwt_key_file` is ignored. The file must exist on the agent. |
| `sfdx_auth_url_file` | No | empty | `authMethod` = `authUrl` | Path to a file whose contents are the SFDX Auth URL (`force://...`). A relative path is resolved from the repository root. When this input is set, the task uses the file and does not use `sfdx_auth_url`. The task fails when the file is missing. |
| `sfdx_auth_url` | No | empty | `authMethod` = `authUrl` | The Auth URL itself, usually a secret variable. Used only when `sfdx_auth_url_file` is empty. The task writes it to `.sf-auth/sfdx-auth-url.txt` and logs in from that file. |

Auth URL mode fails when both `sfdx_auth_url_file` and `sfdx_auth_url` are empty.

## Delta and CLI

| Input | Required | Default | What it does |
|---|---|---|---|
| `sfCliVersion` | No | `2.70.1` | Version passed to `npm install --global @salesforce/cli@<version>`. |
| `skipInstallSfCli` | No | `false` | `true` skips the CLI install. The task then requires `sf` to already be on the agent PATH. |
| `deltaFromRef` | No | `HEAD~1` | Git ref for `sf sgd source delta --from`. `git rev-parse` must succeed. |
| `deltaToRef` | No | `HEAD` | Git ref for `sf sgd source delta --to`. `git rev-parse` must succeed. |
| `ignoreFile` | No | empty | Path to an sfdx-git-delta ignore file (`--ignore-file`). A relative path is resolved from the repository root. When this is empty, the task uses `ignorefile` in the repo root when that file exists, otherwise `.sgdignore` when that file exists. When the given path does not exist, delta runs with no ignore file. |

The task fails when delta does not produce `package/package.xml`.

## Apex test levels

Validate and deploy each have their own test level. Names can be separated by commas, semicolons, or whitespace. Each name is passed as its own `--tests` argument. `RunSpecifiedTests` with no names fails the task.

| Input | Required | Default | What it does |
|---|---|---|---|
| `validateTestLevel` | Yes | `NoTestRun` | `--test-level` on the dry-run. `NoTestRun` runs no tests. `RunLocalTests` runs local tests (org tests outside managed packages). `RunAllTestsInOrg` runs every test in the org. `RunSpecifiedTests` runs only `validateSpecifiedTests`. |
| `validateSpecifiedTests` | Yes when the validate level is `RunSpecifiedTests` | empty | Apex test class names for validation. |
| `deployTestLevel` | Yes | `NoTestRun` | `--test-level` on deploy. Same four values as the validate level. |
| `deploySpecifiedTests` | Yes when the deploy level is `RunSpecifiedTests` | empty | Apex test class names for deployment. |

## Deploy and validate options

| Input | Required | Default | What it does |
|---|---|---|---|
| `deployWaitTime` | No | `120` | Minutes for `sf project deploy start --wait` and for `sf project deploy report --wait`. Used on both validate and deploy. |
| `ignoreWarnings` | No | `false` | `true` adds `--ignore-warnings` on both validate and deploy. |
| `ignoreConflicts` | No | `true` | `true` adds `--ignore-conflicts` on **deploy** only. An empty value is treated as `true`. |

After the CLI command, the task runs `sf project deploy report --use-most-recent`. The run succeeds only when that report contains `Succeeded`. `Failed` or `Canceled` fails the task.

## Code Analyzer (delta only)

These inputs apply when `runCodeAnalyzer` is `true` **and** the resolved operation is **validate**. A deploy run does not install or run the analyzer.

The analyzer workspace is `changed-sources/force-app`. When that folder is missing, the task logs a warning and skips the analyzer.

| Input | Required | Default | Shown when | What it does |
|---|---|---|---|---|
| `runCodeAnalyzer` | No | `false` | Always | `true` installs the `code-analyzer` plugin and runs it on delta sources during validate. |
| `useCustomPmdRuleset` | No | `false` | `runCodeAnalyzer` = `true` | `true` uses `pmdRulesetPath`. `false` uses `codeAnalyzerRuleSelector`. |
| `pmdRulesetPath` | Yes when custom rules are on | empty | custom PMD is on | Path to a PMD ruleset `.xml` in the repo or on the agent. The task writes `reports/code-analyzer-pmd-config.yml` pointing at that file and runs with `--rule-selector pmd`. The task fails when the path is empty or the file is missing. |
| `codeAnalyzerRuleSelector` | No | `all` | custom PMD is off | Passed as `--rule-selector`. |
| `codeAnalyzerSeverityThreshold` | No | `2` | `runCodeAnalyzer` = `true` | Passed as `--severity-threshold` to `sf code-analyzer run`. |
| `enforceSeverityGate` | No | `true` | `runCodeAnalyzer` = `true` | After the run, reads `reports/code-analyzer-report.csv`. A finding fails the task when its numeric severity is **greater than** `maxAllowedSeverity`. Text values are mapped as `critical` / `high` / `sev1` = 1, `error` / `medium` / `sev2` = 2, `warning` / `low` / `sev3` = 3, `info` / `sev4` = 4. A missing CSV skips the gate with a warning. |
| `maxAllowedSeverity` | No | `2` | `runCodeAnalyzer` = `true` | Integer limit for the CSV gate. A non-numeric value is treated as `2`. |

## Artifacts

| Input | Required | Default | Shown when | What it does |
|---|---|---|---|---|
| `publishDeltaArtifact` | No | `true` | Always | `true` publishes the `artifacts` folder (timestamped `package_*.xml` and, when present, `destructiveChanges_*.xml`) after validate or deploy succeeds. |
| `deltaArtifactName` | No | `Delta-Package` | Always | Name of that pipeline artifact. Pipeline variables in the value are expanded by Azure DevOps before the task runs. |
| `publishCodeAnalyzerArtifact` | No | `false` | `runCodeAnalyzer` = `true` | `true` publishes the `reports` folder. This happens only when the analyzer actually ran (validate + `runCodeAnalyzer`). |
| `codeAnalyzerArtifactName` | No | `sf-code-analyzer` | `runCodeAnalyzer` = `true` | Name of the Code Analyzer pipeline artifact. |
