#!/bin/bash
# Auto-Reflect Hook Wrapper
# Calls the Node.js implementation for transcript analysis

cd "$(dirname "$0")" || exit 0
node auto-reflect.js
