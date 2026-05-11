#!/usr/bin/env node
/**
 * Skill Activation Prompt Hook
 *
 * Reads skill-rules.json, matches user prompt against triggers,
 * and injects the matching SKILL.md content into the conversation.
 *
 * Supports both /skill:name and /name trigger patterns.
 */

const { readFileSync, existsSync, readdirSync, statSync } = require('fs');
const { join, dirname } = require('path');

const PROJECT_DIR = process.env.PROJECT_DIR || process.cwd();
const OPENCODE_DIR = join(PROJECT_DIR, '.opencode');
const RULES_FILE = join(OPENCODE_DIR, 'skill-rules.json');

/**
 * Recursively find SKILL.md for a given skill name
 */
function findSkillFile(skillName) {
  const searchDirs = [
    join(OPENCODE_DIR, 'skills', 'dev'),
    join(OPENCODE_DIR, 'skills', 'operation'),
    join(OPENCODE_DIR, 'skills', 'qa'),
    join(OPENCODE_DIR, 'skills'),
  ];

  for (const dir of searchDirs) {
    if (!existsSync(dir)) continue;
    const found = searchSkillDir(dir, skillName);
    if (found) return found;
  }
  return null;
}

function searchSkillDir(dir, skillName) {
  const entries = readdirSync(dir);
  for (const entry of entries) {
    const entryPath = join(dir, entry);
    const stat = statSync(entryPath);
    if (stat.isDirectory()) {
      if (entry === skillName) {
        const skillFile = join(entryPath, 'SKILL.md');
        if (existsSync(skillFile)) return skillFile;
      }
      // Recurse one level deeper
      try {
        const subEntries = readdirSync(entryPath);
        for (const sub of subEntries) {
          const subPath = join(entryPath, sub);
          if (statSync(subPath).isDirectory() && sub === skillName) {
            const skillFile = join(subPath, 'SKILL.md');
            if (existsSync(skillFile)) return skillFile;
          }
        }
      } catch { /* ignore */ }
    }
  }
  return null;
}

/**
 * Load skill rules from skill-rules.json
 */
function loadSkillRules() {
  if (!existsSync(RULES_FILE)) {
    return { version: '1.0', rules: [] };
  }
  try {
    return JSON.parse(readFileSync(RULES_FILE, 'utf-8'));
  } catch {
    return { version: '1.0', rules: [] };
  }
}

/**
 * Match prompt against skill triggers
 * Supports exact triggers like /commit, /skill:commit, etc.
 */
function matchSkills(rules, prompt) {
  const matches = [];
  const promptTrimmed = prompt.trim();
  const promptLower = promptTrimmed.toLowerCase();

  for (const rule of rules) {
    const trigger = rule.trigger || '';
    const triggerLower = trigger.toLowerCase();
    const name = rule.name || '';

    // Exact trigger match: /skill:commit or /commit
    let matched = false;
    if (promptTrimmed === trigger || promptTrimmed.startsWith(trigger + ' ')) {
      matched = true;
    }
    // Also match /name as alias for /skill:name
    const shortTrigger = '/' + name;
    if (promptTrimmed === shortTrigger || promptTrimmed.startsWith(shortTrigger + ' ')) {
      matched = true;
    }
    // Keyword fallback: if prompt contains the skill name as a word
    if (!matched) {
      const keywords = (rule.keywords || [name]).map(k => k.toLowerCase());
      for (const kw of keywords) {
        if (promptLower.includes(kw)) {
          matched = true;
          break;
        }
      }
    }

    if (matched) {
      matches.push(rule);
    }
  }

  return matches;
}

function main() {
  try {
    // Read hook input from stdin (JSON)
    const input = readFileSync(0, 'utf-8');
    let data;
    try {
      data = JSON.parse(input);
    } catch {
      // If not JSON, treat stdin as raw prompt
      data = { prompt: input };
    }

    const prompt = data.prompt || '';
    const rules = loadSkillRules();
    const matches = matchSkills(rules.rules || [], prompt);

    if (matches.length === 0) {
      process.exit(0);
    }

    let output = '';

    for (const rule of matches) {
      const skillFile = findSkillFile(rule.name);
      if (!skillFile) {
        output += `\n[opencode] Skill "${rule.name}" matched but SKILL.md not found.\n`;
        continue;
      }

      const skillContent = readFileSync(skillFile, 'utf-8');
      output += `\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n`;
      output += `  SKILL ACTIVATED: ${rule.name.toUpperCase()}\n`;
      output += `  Trigger: ${rule.trigger}\n`;
      output += `  Description: ${rule.description || ''}\n`;
      output += `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n`;
      output += skillContent;
      output += `\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n`;
      output += `  END SKILL: ${rule.name.toUpperCase()}\n`;
      output += `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n`;
    }

    console.log(output);
    process.exit(0);
  } catch (err) {
    console.error('[skill-activation-prompt] Error:', err.message);
    process.exit(0); // Fail silently so conversation isn't blocked
  }
}

main();
