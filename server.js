#!/usr/bin/env node
'use strict';

/**
 * Pterodactyl entrypoint shim.
 *
 * The egg's startup command ends with:
 *     /usr/local/bin/node /home/container/server.js
 *
 * So this file must exist at the repo root. It delegates to start.sh, which
 * does the real work (resolve latest release, download static binary, write
 * config, exec). Keeping the logic in one shell file means the same code path
 * is used whether you run `sh start.sh` or the panel's default command.
 */

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const dir = __dirname;
const script = path.join(dir, 'start.sh');

if (!fs.existsSync(script)) {
  console.error('[cpa] ERROR: start.sh not found next to server.js');
  process.exit(1);
}

const child = spawn('sh', [script], {
  stdio: 'inherit',
  cwd: dir,
  // Panels sometimes export a stale PWD; force it so start.sh installs here.
  env: Object.assign({}, process.env, {
    PWD: dir,
    INSTALL_DIR: process.env.INSTALL_DIR || dir,
  }),
});

child.on('error', (err) => {
  console.error('[cpa] failed to launch start.sh:', err.message);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code === null ? 1 : code);
});

// Forward panel stop signals so the binary shuts down cleanly instead of
// being SIGKILLed after the grace period.
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(sig, () => {
    try {
      child.kill(sig);
    } catch (_) {
      /* already gone */
    }
  });
}
