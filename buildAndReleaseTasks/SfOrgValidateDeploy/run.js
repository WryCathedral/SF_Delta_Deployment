const { spawnSync } = require('child_process');
const path = require('path');

const scriptPath = path.join(__dirname, 'sf-delta.ps1');

function canStart(command) {
    const probe = spawnSync(
        command,
        ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0'],
        { stdio: 'ignore', windowsHide: true }
    );
    return !probe.error && probe.status === 0;
}

function resolveShell() {
    if (canStart('pwsh')) {
        return 'pwsh';
    }
    if (process.platform === 'win32' && canStart('powershell')) {
        return 'powershell';
    }
    return null;
}

const shell = resolveShell();
if (!shell) {
    console.error('##vso[task.logissue type=error]PowerShell was not found on this agent. Microsoft-hosted ubuntu-latest and windows-latest images include PowerShell 7 (pwsh). On a self-hosted agent, install PowerShell 7 and ensure pwsh is on PATH.');
    process.exit(1);
}

const result = spawnSync(
    shell,
    [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', scriptPath
    ],
    {
        stdio: 'inherit',
        env: process.env,
        windowsHide: true
    }
);

if (result.error) {
    console.error(`##vso[task.logissue type=error]Failed to start ${shell}: ${result.error.message}`);
    process.exit(1);
}

process.exit(result.status === null ? 1 : result.status);
