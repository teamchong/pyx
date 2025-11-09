# Zyth

Python to Zig compiler. Write Python, run native code.

**35x faster** than CPython on fibonacci(40) | Native binaries | Zero interpreter overhead

## Quick Start

```bash
# Clone and setup
git clone <repo-url> zyth
cd zyth
make install-dev

# Activate environment
source .venv/bin/activate

# Compile and run
zyth examples/fibonacci.py --run
```

## Installation

### Development Setup (Contributors)

```bash
make install-dev
source .venv/bin/activate
zyth --help
```

### Production Install (Users)

```bash
# From PyPI (when published)
pip install zyth-cli
zyth --help

# Or with pipx (isolated)
pipx install zyth-cli
```

### Manual Install

```bash
# From source
uv pip install -e packages/cli

# Activate venv
source .venv/bin/activate
zyth --help
```

## Usage

```bash
# Compile Python to native binary
zyth app.py

# Compile and run immediately
zyth app.py --run

# Specify output path
zyth app.py -o my_binary

# Show generated Zig code
zyth app.py --show-zig
```

## Example

**Input (examples/fibonacci.py):**
```python
def fibonacci(n: int) -> int:
    if n <= 1:
        return n
    return fibonacci(n - 1) + fibonacci(n - 2)

result = fibonacci(10)
print(result)
```

**Compile:**
```bash
zyth examples/fibonacci.py -o fib
./fib
# Output: 55
```

## Performance

| Test | CPython | Zyth | Speedup |
|------|---------|------|---------|
| fibonacci(30) | 96ms | 25ms | **3.9x** |
| fibonacci(35) | 1068ms | 47ms | **22.7x** |
| fibonacci(40) | 12187ms | 343ms | **35.6x** |

## Features

**Current:**
- ✅ Function definitions with type hints
- ✅ Integer arithmetic and recursion
- ✅ If/else statements
- ✅ Binary compilation to native code
- ✅ 35x performance improvement

**Roadmap:**
- [ ] Lists, dicts, strings
- [ ] Classes and methods
- [ ] Standard library (zyth.web, zyth.http, zyth.ai)
- [ ] WebAssembly target
- [ ] Goroutines and channels

## Project Structure

```
zyth/
├── packages/
│   ├── core/       # Compiler (parser, codegen)
│   ├── runtime/    # Zig runtime library
│   ├── cli/        # Command-line tool
│   ├── web/        # zyth.web (future)
│   ├── http/       # zyth.http (future)
│   └── ai/         # zyth.ai (future)
├── examples/       # Example programs
└── docs/          # Documentation
```

## Development

```bash
# Run tests
make test         # Python tests
make test-zig     # Zig runtime tests

# Code quality
make lint         # Run linter
make format       # Format code
make typecheck    # Type check

# Run example
make run FILE=examples/fibonacci.py

# Clean build artifacts
make clean
```

## Requirements

- Python 3.10+
- Zig 0.15.2+
- uv (recommended) or pip

## Documentation

See `docs/` for detailed documentation:
- [Architecture](docs/ARCHITECTURE.md)
- [Compilation Flow](docs/COMPILATION_FLOW.md)
- [Monorepo Structure](docs/MONOREPO_STRUCTURE.md)

## Status

**Phase 0: Proof of Concept** ✅

Validates core functionality. Production-ready compiler in development.

## License

[Add license]

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) (coming soon)
