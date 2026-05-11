#!/bin/bash
# Status Auto-Updater Hook Wrapper
# Calls the Node.js implementation for status file updates

cd "$PROJECT_DIR/.opencode/hooks" || exit 0
node status-auto-updater.js
