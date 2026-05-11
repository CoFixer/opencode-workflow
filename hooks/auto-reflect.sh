#!/bin/bash
# Auto-Reflect Hook Wrapper
# Calls the Node.js implementation for transcript analysis

cd "$PROJECT_DIR/.opencode/hooks" || exit 0
node auto-reflect.js
