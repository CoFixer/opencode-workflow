#!/bin/bash
# Skill Activation Prompt Hook Wrapper
# Calls the Node.js implementation for JSON parsing and skill loading

cd "$PROJECT_DIR/.opencode/hooks" || exit 0
node skill-activation-prompt.js
