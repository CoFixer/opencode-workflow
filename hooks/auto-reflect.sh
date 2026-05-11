#!/bin/bash
# Auto-reflect hook - triggers at session stop
# Updates .project/memory/LEARNINGS.md with session insights

PROJECT_DIR="${PROJECT_DIR:-.}"
MEMORY_DIR="$PROJECT_DIR/.project/memory"

# Only run if .project exists
if [ ! -d "$MEMORY_DIR" ]; then
  exit 0
fi

# Check if reflection is enabled
if [ -f "$PROJECT_DIR/.opencode/settings.json" ]; then
  REFLECT_MODE=$(grep -o '"reflectMode": *"[^"]*"' "$PROJECT_DIR/.opencode/settings.json" | sed 's/.*: *"\([^"]*\)".*/\1/')
  if [ "$REFLECT_MODE" = "off" ]; then
    exit 0
  fi
fi

# Append session marker to LEARNINGS.md
echo "" >> "$MEMORY_DIR/LEARNINGS.md"
echo "## $(date +%Y-%m-%d): Session End" >> "$MEMORY_DIR/LEARNINGS.md"
echo "Session completed. Review conversation for patterns to extract." >> "$MEMORY_DIR/LEARNINGS.md"
