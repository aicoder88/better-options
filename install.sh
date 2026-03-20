#!/bin/bash
set -e

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
INSTALL_DIR="$HOME/.claude/claude-statusline"
BACKUP_FILE="$HOME/.claude/settings.json.backup"

echo "🔍 Checking prerequisites..."

# Check if Claude settings exists
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo "❌ Error: Claude settings not found at $CLAUDE_SETTINGS"
  echo "   Please ensure Claude Code is installed and has been run at least once."
  exit 1
fi

# Check if Bun is installed
if ! command -v bun &> /dev/null; then
  echo "⚠️  Bun is not installed."
  echo "   Install it with: curl -fsSL https://bun.sh/install | bash"
  echo "   Or visit: https://bun.sh"
  exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo "⚠️  jq is not installed (required for JSON manipulation)."
  echo "   Install it with:"
  echo "   - macOS: brew install jq"
  echo "   - Linux: apt-get install jq or yum install jq"
  exit 1
fi

echo "✓ Prerequisites check passed"
echo ""

# Check if config already matches target
STATUSLINE_CMD="bun $INSTALL_DIR/statusline.ts"
CURRENT_CMD=""
if jq -e '.statusLine.command' "$CLAUDE_SETTINGS" &> /dev/null; then
  CURRENT_CMD=$(jq -r '.statusLine.command' "$CLAUDE_SETTINGS")
fi

if [ "$CURRENT_CMD" = "$STATUSLINE_CMD" ]; then
  echo "✓ Settings already configured correctly!"
  echo ""
  echo "📋 Current statusLine config:"
  jq '.statusLine' "$CLAUDE_SETTINGS"
  echo ""
  if [ -d "$INSTALL_DIR" ]; then
    read -p "❓ Update code to latest version? (Y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
      echo "Nothing to do. Exiting."
      exit 0
    fi
  else
    read -p "❓ Download statusline code? (Y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
      echo "Installation cancelled."
      exit 0
    fi
  fi
  SKIP_SETTINGS_UPDATE=true
else
  # Show what will be done
  echo "📋 This will:"
  echo "   1. Download/update claude-statusline to $INSTALL_DIR"
  echo "   2. Install dependencies with bun"
  echo "   3. Backup current settings to $BACKUP_FILE"
  echo "   4. Add/update statusLine configuration in $CLAUDE_SETTINGS"
  echo ""
  echo "────────────────────────────────────────────────────────────────"
  echo "BEFORE:"
  cat "$CLAUDE_SETTINGS" | jq '.'
  echo ""
  echo "AFTER:"
  jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"type": "command", "command": $cmd}' "$CLAUDE_SETTINGS"
  echo "────────────────────────────────────────────────────────────────"
  echo ""

  # Prompt for confirmation
  read -p "❓ Continue? (Y/n) " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Installation cancelled."
    exit 0
  fi
  SKIP_SETTINGS_UPDATE=false
fi

echo ""
echo "🚀 Installing..."

# Check if already installed
if [ -d "$INSTALL_DIR" ]; then
  echo "📦 Updating..."
  cd "$INSTALL_DIR"
  git pull --quiet
else
  echo "📦 Downloading statusline..."
  git clone --quiet https://github.com/bitbonsai/claude-status.git "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi

# Install dependencies
echo "📦 Installing dependencies..."
bun install --silent

# Update settings only if needed
if [ "$SKIP_SETTINGS_UPDATE" = false ]; then
  # Backup settings (overwrite previous backup)
  echo "💾 Backing up settings..."
  cp "$CLAUDE_SETTINGS" "$BACKUP_FILE"

  # Update settings.json with jq
  echo "⚙️  Updating settings..."

  # If file is empty or invalid JSON, initialize with empty object
  if [ ! -s "$CLAUDE_SETTINGS" ] || ! jq empty "$CLAUDE_SETTINGS" &>/dev/null; then
    echo "{}" > "$CLAUDE_SETTINGS"
  fi

  jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"type": "command", "command": $cmd}' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp"
  mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"

  echo ""
  echo "✅ Installation complete!"
  echo ""
  echo "   Backup saved to: $BACKUP_FILE"
  echo "   Settings updated: $CLAUDE_SETTINGS"
  echo "   The statusline will reload automatically."
else
  echo ""
  echo "✅ Update complete!"
  echo ""
  echo "   Code updated at: $INSTALL_DIR"
  echo "   Settings unchanged (already configured correctly)"
fi
