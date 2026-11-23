// Stand-in for the Salesforce CLI, used only by tests/Test-EndToEnd.ps1.
// It records every call to SF_FAKE_LOG and answers the commands the task issues.
'use strict';
const fs = require('fs');
const path = require('path');

const argv = process.argv.slice(2);
if (process.env.SF_FAKE_LOG) {
  fs.appendFileSync(process.env.SF_FAKE_LOG, JSON.stringify({ cwd: process.cwd(), argv }) + '\n');
}

const opt = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const is = (...words) => words.every((w, i) => argv[i] === w);

function copyFixture(envName, destRelative) {
  const source = process.env[envName];
  if (!source) return;
  const dest = path.join(process.cwd(), destRelative);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(source, dest);
}

if (is('--version')) {
  console.log('@salesforce/cli/2.99.0 win32-x64 node-v25.9.0');
} else if (is('plugins', 'install')) {
  console.log(`Installing plugin ${argv[2]}... installed v6.0.0`);
} else if (is('plugins')) {
  console.log(JSON.stringify({ status: 0, result: [] }));
} else if (is('org', 'login')) {
  console.log('Successfully authorized fake@example.com with org ID 00D000000000001');
} else if (is('alias', 'list')) {
  console.log('Alias  Value\nqa     fake@example.com');
} else if (is('sgd', 'source', 'delta')) {
  copyFixture('SF_FAKE_PACKAGE', 'package/package.xml');
  copyFixture('SF_FAKE_DESTRUCTIVE', 'destructiveChanges/destructiveChanges.xml');
  console.log('Generating incremental package... Success');
} else if (is('data', 'query')) {
  if (process.env.SF_FAKE_QUERY_FAIL === '1') {
    console.error('ERROR running data query: INVALID_SESSION_ID');
    process.exit(1);
  }
  const query = opt('--query') || '';
  const names = [...query.matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((m) => m[1]);
  const orgFlows = JSON.parse(process.env.SF_FAKE_FLOWS || '{}');
  const records = [];
  for (const name of names) {
    for (const version of orgFlows[name] || []) {
      records.push({
        attributes: { type: 'Flow' },
        VersionNumber: version,
        Definition: { attributes: { type: 'FlowDefinition' }, DeveloperName: name },
      });
    }
  }
  console.log(JSON.stringify({ status: 0, result: { size: records.length, totalSize: records.length, records } }));
} else if (is('project', 'deploy', 'start')) {
  const dry = argv.includes('--dry-run');
  console.log(dry ? 'Deploying (dry-run) metadata' : 'Deploying metadata');
  console.log('Status: ' + (process.env.SF_FAKE_DEPLOY_EXIT === '1' ? 'Failed' : 'Succeeded'));
  process.exit(process.env.SF_FAKE_DEPLOY_EXIT === '1' ? 1 : 0);
} else if (is('project', 'deploy', 'report')) {
  const failed = process.env.SF_FAKE_DEPLOY_EXIT === '1';
  // Same shape as a real report: the details block always carries these arrays.
  const details = { componentFailures: [], componentSuccesses: [], runTestResult: {} };
  console.log(JSON.stringify({ status: 0, result: { status: failed ? 'Failed' : 'Succeeded', details } }));
} else {
  console.log('fake sf: unhandled command ' + argv.join(' '));
}
process.exit(0);
