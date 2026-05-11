#!/bin/bash
# Skill activation prompt hook
# Suggests relevant skills based on user prompt keywords

PROJECT_DIR="${PROJECT_DIR:-.}"
PROMPT="$1"

# Keyword → skill mappings
case "$PROMPT" in
  *commit*|*"git commit"*|*"ship changes"*)
    echo "💡 Tip: Use /skill:commit to run the full commit & PR workflow"
    ;;
  *"find gap"*|*"check gap"*|*"missing"*|*"what's left"*)
    echo "💡 Tip: Use /skill:find-gaps to scan for implementation gaps"
    ;;
  *"fix gap"*|*"fix issue"*|*"resolve gap"*)
    echo "💡 Tip: Use /skill:fix-gaps to fix identified gaps"
    ;;
  *"generate doc"*|*"update doc"*|*"documentation"*)
    echo "💡 Tip: Use /skill:generate-docs to generate project documentation"
    ;;
  *"fullstack"*|*"backend and frontend"*|*"run pipeline"*)
    echo "💡 Tip: Use /skill:run-fullstack to run the development pipeline"
    ;;
  *"reflect"*|*"what did we learn"*|*"session summary"*)
    echo "💡 Tip: Use /skill:reflect to analyze session learnings"
    ;;
esac
