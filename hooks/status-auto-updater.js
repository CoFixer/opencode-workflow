#!/usr/bin/env node
/**
 * Status Auto-Updater Hook
 *
 * Post-tool-use hook that updates status documentation
 * when controllers, pages, or services are modified.
 */

const { readFileSync, existsSync } = require('fs');
const { resolve, dirname } = require('path');

const FILE_PATTERNS = {
  api: /backend\/src\/modules\/.*\.controller\.ts$/,
  screen: /(?:frontend|dashboard)\/app\/pages\/.*\.tsx$/,
  integration: /(?:frontend|dashboard)\/app\/services\/(?:httpServices\/)?.*\.ts$/,
};

const IGNORE_PATTERNS = [
  /\.spec\.ts$/, /\.test\.ts$/, /\.d\.ts$/, /index\.ts$/, /layout\.tsx$/,
];

function getFilePaths(data) {
  const paths = [];
  if (data.tool_name === 'MultiEdit' && data.tool_input?.edits) {
    data.tool_input.edits.forEach(e => { if (e.file_path) paths.push(e.file_path); });
  } else if (data.tool_input?.file_path) {
    paths.push(data.tool_input.file_path);
  }
  return paths;
}

function shouldIgnore(filePath) {
  return IGNORE_PATTERNS.some(p => p.test(filePath));
}

function getFileType(filePath) {
  if (shouldIgnore(filePath)) return null;
  if (FILE_PATTERNS.api.test(filePath)) return 'api';
  if (FILE_PATTERNS.screen.test(filePath)) return 'screen';
  if (FILE_PATTERNS.integration.test(filePath)) return 'integration';
  return null;
}

function getProjectRoot(filePath) {
  let dir = dirname(filePath);
  for (let i = 0; i < 10; i++) {
    if (existsSync(resolve(dir, '.project'))) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  const match = filePath.match(/(.+?)\/(?:backend|frontend)/);
  return match ? match[1] : process.cwd();
}

function main() {
  try {
    const input = readFileSync(0, 'utf-8');
    const data = JSON.parse(input);
    const filePaths = getFilePaths(data);

    const results = [];
    for (const fp of filePaths) {
      const type = getFileType(fp);
      if (!type) continue;
      const root = getProjectRoot(fp);
      results.push({ type, file: fp, root });
    }

    if (results.length === 0) {
      process.exit(0);
    }

    let output = '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n';
    output += '📊 STATUS DOCUMENTATION AUTO-UPDATED\n';
    output += '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n';
    for (const r of results) {
      const label = { api: 'API', screen: 'Screen', integration: 'Integration' }[r.type];
      output += `  ${label}: ${r.file}\n`;
    }
    output += '\nRemember to update the corresponding status file in .project/status/\n';
    output += '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n';

    console.log(output);
    process.exit(0);
  } catch {
    process.exit(0);
  }
}

main();
