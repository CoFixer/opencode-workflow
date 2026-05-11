#!/bin/bash
# Status auto-updater hook - triggers at session stop
# Updates status files with progress markers

PROJECT_DIR="${PROJECT_DIR:-.}"
STATUS_DIR="$PROJECT_DIR/.project/status"

# Only run if .project exists
if [ ! -d "$STATUS_DIR" ]; then
  exit 0
fi

# Update temp status with session end time
TEMP_DIR="$STATUS_DIR/temp"
mkdir -p "$TEMP_DIR"

echo "{ \"lastSessionEnd\": \"$(date -Iseconds)\" }" > "$TEMP_DIR/session-tracker.json"
