#!/bin/bash
set -e

# Zyth Development Installation Script

echo "🔧 Setting up Zyth development environment..."

# Check prerequisites
command -v uv >/dev/null 2>&1 || { echo "❌ Error: uv not installed. Install from https://docs.astral.sh/uv/"; exit 1; }
command -v zig >/dev/null 2>&1 || { echo "❌ Error: zig not installed. Install from https://ziglang.org/"; exit 1; }

# Sync workspace
echo "📦 Installing workspace packages..."
uv sync

# Install all packages in editable mode
echo "🔗 Installing packages in editable mode..."
uv pip install -e packages/core -e packages/runtime -e packages/cli -e packages/web -e packages/http -e packages/ai -e packages/async -e packages/db

# Add venv bin to PATH (for current shell)
VENV_BIN="$(pwd)/.venv/bin"

echo ""
echo "✅ Development environment ready!"
echo ""
echo "To use zyth command, add to your shell:"
echo ""
echo "  export PATH=\"$VENV_BIN:\$PATH\""
echo ""
echo "Or activate the virtual environment:"
echo ""
echo "  source .venv/bin/activate"
echo ""
echo "Then run:"
echo "  zyth examples/fibonacci.py --run"
echo ""
