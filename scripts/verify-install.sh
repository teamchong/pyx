#!/bin/bash
# Verify Zyth installation

set -e

echo "🔍 Verifying Zyth installation..."
echo ""

# Check zyth command exists
if command -v zyth >/dev/null 2>&1; then
    echo "✅ zyth command found in PATH"
else
    echo "❌ zyth command not found"
    echo "   Run: source .venv/bin/activate"
    exit 1
fi

# Test help
echo "✅ Testing --help..."
zyth --help >/dev/null

# Test compilation
echo "✅ Testing compilation..."
zyth examples/fibonacci.py -o /tmp/zyth_verify_test >/dev/null 2>&1

# Test execution
echo "✅ Testing execution..."
OUTPUT=$(/tmp/zyth_verify_test 2>&1)
if [ "$OUTPUT" = "55" ]; then
    echo "✅ Output correct: $OUTPUT"
else
    echo "❌ Output incorrect: '$OUTPUT' (expected '55')"
    exit 1
fi

# Clean up
rm -f /tmp/zyth_verify_test

echo ""
echo "✅ All checks passed! Zyth is properly installed."
echo ""
echo "Try: zyth examples/fibonacci.py --run"
echo ""
