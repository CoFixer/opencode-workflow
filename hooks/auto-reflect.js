#!/usr/bin/env node
/**
 * Auto-Reflect Hook
 *
 * Analyzes conversation transcript for learnings on Stop event.
 * Appends HIGH confidence learnings to .project/memory/LEARNINGS.md
 */

const { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync } = require('fs');
const { join, dirname } = require('path');
const { execSync } = require('child_process');

const PROJECT_DIR = dirname(dirname(__dirname));
const MEMORY_DIR = join(PROJECT_DIR, '.project', 'memory');
const LEARNINGS_FILE = join(MEMORY_DIR, 'LEARNINGS.md');

const CORRECTION_PATTERNS = [
  /\b(no,?\s|nope|don't|do not|wrong|incorrect|that's not right|instead|rather|actually)\b/i,
  /\bi meant\b/i,
  /\bplease (change|fix|update|correct)\b/i,
  /\bnever\s+(do|use|add)\b/i,
];

const PREFERENCE_PATTERNS = [
  /\bi (prefer|like to|always|never|want to)\b/i,
  /\bwe (always|never|usually|typically)\b/i,
  /\bour (convention|standard|approach|pattern)\b/i,
];

function initializeMemoryFiles() {
  if (!existsSync(MEMORY_DIR)) {
    mkdirSync(MEMORY_DIR, { recursive: true });
  }
  if (!existsSync(LEARNINGS_FILE)) {
    writeFileSync(
      LEARNINGS_FILE,
      `# Session Learnings\n\nAuto-captured learnings from conversation analysis.\n\n---\n\n## Entries\n\n`,
    );
  }
}

function extractUserMessages(transcript) {
  const messages = [];
  const lines = transcript.split('\n');
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      if (entry.type === 'user' && entry.message?.content) {
        let text = '';
        if (Array.isArray(entry.message.content)) {
          text = entry.message.content
            .filter(b => b.type === 'text')
            .map(b => b.text || '')
            .join(' ');
        } else if (typeof entry.message.content === 'string') {
          text = entry.message.content;
        }
        text = text.trim();
        if (text && text.length < 500 && !text.startsWith('---')) {
          messages.push(text);
        }
      }
    } catch { /* skip non-JSON lines */ }
  }
  return messages;
}

function detectSignals(messages) {
  const corrections = [];
  const preferences = [];
  for (const msg of messages) {
    if (CORRECTION_PATTERNS.some(p => p.test(msg))) {
      corrections.push(msg);
    } else if (PREFERENCE_PATTERNS.some(p => p.test(msg))) {
      preferences.push(msg);
    }
  }
  return { corrections, preferences };
}

function formatLearning(text, type) {
  const date = new Date().toISOString().split('T')[0];
  return `\n### ${date}: ${type.toUpperCase()}\n\n**Type**: ${type}\n**Confidence**: HIGH\n**Source**: Auto-reflection\n\n**Description**: ${text}\n\n---\n`;
}

function main() {
  try {
    const input = readFileSync(0, 'utf-8');
    let data;
    try {
      data = JSON.parse(input);
    } catch {
      process.exit(0);
    }

    if (!data.transcript_path || !existsSync(data.transcript_path)) {
      process.exit(0);
    }

    const transcript = readFileSync(data.transcript_path, 'utf-8');
    const userMessages = extractUserMessages(transcript);
    const signals = detectSignals(userMessages);

    const learnings = [];
    for (const c of signals.corrections) {
      learnings.push(formatLearning(c, 'correction'));
    }
    for (const p of signals.preferences) {
      learnings.push(formatLearning(p, 'preference'));
    }

    if (learnings.length === 0) {
      process.exit(0);
    }

    initializeMemoryFiles();
    appendFileSync(LEARNINGS_FILE, learnings.join(''));

    // Try to commit
    try {
      execSync('git add .project/memory/', { cwd: PROJECT_DIR, stdio: 'ignore' });
      execSync('git commit -m "reflect(auto): capture learnings"', { cwd: PROJECT_DIR, stdio: 'ignore' });
    } catch { /* ignore git errors */ }

    console.error(`\n[reflect] Auto-captured ${learnings.length} learning(s)\n`);
    process.exit(0);
  } catch {
    process.exit(0);
  }
}

main();
