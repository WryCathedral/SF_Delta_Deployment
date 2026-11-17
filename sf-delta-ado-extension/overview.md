# Salesforce Delta Pipeline extension

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

## Publishing the VSIX

1. Install [Node.js](https://nodejs.org/) and the packaging tool: `npm install -g tfx-cli` (see [tfs-cli](https://github.com/Microsoft/tfs-cli)).
2. Replace `YOUR_PUBLISHER_ID` in `vss-extension.json` with your [Azure DevOps publisher](https://learn.microsoft.com/en-us/azure/devops/extend/publish/overview).
3. From this folder run: `tfx extension create --manifest-globs vss-extension.json`
4. Upload the `.vsix` under **Organization settings** &rarr; **Extensions** &rarr; **Shared**, then install it for your project collection.

More detail: [Add a custom pipelines task](https://learn.microsoft.com/en-us/azure/devops/extend/develop/add-build-task?view=azure-devops).
