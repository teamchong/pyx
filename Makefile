.PHONY: help build install verify test test-zig lint format typecheck clean run benchmark

help:
	@echo "Zyth Commands"
	@echo "============="
	@echo "build    - Build zyth compiler binary"
	@echo "install  - Install zyth to ~/.local/bin"
	@echo "verify   - Verify installation is working"
	@echo "test     - Run Python tests (legacy)"
	@echo "test-zig - Run Zig runtime tests"
	@echo "clean    - Remove build artifacts"

build:
	@echo "🔨 Building zyth compiler..."
	@command -v zig >/dev/null 2>&1 || { echo "❌ Error: zig not installed"; exit 1; }
	zig build
	@echo "✅ Binary built: zig-out/bin/zyth"

install: build
	@echo "📦 Installing zyth to ~/.local/bin..."
	@mkdir -p ~/.local/bin
	@cp zig-out/bin/zyth ~/.local/bin/zyth
	@chmod +x ~/.local/bin/zyth
	@echo ""
	@echo "✅ Zyth installed!"
	@echo ""
	@echo "Make sure ~/.local/bin is in your PATH:"
	@echo "  export PATH=\"\$$HOME/.local/bin:\$$PATH\""
	@echo ""
	@echo "Then run: zyth your_file.py"
	@echo ""

verify:
	@bash scripts/verify-install.sh

test:
	uv run pytest packages/*/tests -v

test-zig:
	zig test packages/runtime/src/runtime.zig
	@echo "✅ Zig runtime tests passed"

lint:
	uv run ruff check packages/

format:
	uv run ruff format packages/

typecheck:
	uv run mypy packages/

clean:
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".mypy_cache" -exec rm -rf {} + 2>/dev/null || true
	rm -rf bin/ output fib_binary test_output

run:
	@echo "⚠️  DEPRECATED: Use 'zyth' command directly instead"
	@echo "    New: zyth $(FILE)"
	@echo ""
	uv run zyth $(FILE)

benchmark:
	uv run python _prototype/benchmark.py
