# Zyth

**v0.1.0-alpha** - Early development, not production-ready

Python to Zig AOT compiler. Write Python, run native code.

**Up to 41x faster** than CPython | Native binaries | Zero interpreter overhead

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

| Benchmark | CPython | Zyth | Speedup |
|:---|---:|---:|---:|
| **Loop sum (1M)** | 65.4 ms | 1.6 ms | **41.40x faster** 🔥 |
| **Fibonacci(35)** | 804.5 ms | 28.2 ms | **28.56x faster** 🚀 |
| **List methods** | 22.1 ms | 1.5 ms | **14.89x faster** ⚡ |
| **List operations** | 22.3 ms | 1.6 ms | **13.98x faster** ⚡ |
| **String concat** | 23.6 ms | 1.9 ms | **12.24x faster** ⚡ |

**Benchmarked with [hyperfine](https://github.com/sharkdp/hyperfine)** on macOS ARM64.

Raw results: [loop_sum_results.md](benchmarks/loop_sum_results.md) · [fibonacci_results.md](benchmarks/fibonacci_results.md) · [list_methods_results.md](benchmarks/list_methods_results.md) · [list_ops_results.md](benchmarks/list_ops_results.md) · [string_results.md](benchmarks/string_results.md)

## Features

### ✅ Implemented (78/140 tests passing)

**Core Language:**
- ✅ Function definitions with return values
- ✅ Class inheritance with `super()`
- ✅ Control flow (if/else, while, for loops)
- ✅ Variable reassignment detection (var vs const)
- ✅ Tuples with element type tracking
- ✅ Import/module system (6/8 tests passing)

**Data Types:**
- ✅ Lists (literals, indexing, slicing, comprehensions)
- ✅ Strings (literals, slicing, concatenation)
- ✅ Dicts (literals, key access)
- ✅ Integers (primitives and PyObject)

**Built-in Methods (19 total):**
- ✅ String: `upper()`, `lower()`, `split()`, `strip()`, `replace()`, `find()`, `count()`
- ✅ List: `append()`, `pop()`, `extend()`, `remove()`, `reverse()`, `count()`, `index()`, `insert()`, `clear()`, `copy()`
- ✅ Dict: `get()`, `keys()`, `values()`, `items()`, `copy()`

**Advanced Features:**
- ✅ List comprehensions with filters
- ✅ List/string slicing with step (e.g., `nums[1:5:2]`)
- ✅ Mixed type operations (primitive + PyObject)
- ✅ Automatic memory management (reference counting)
- ✅ Timestamp-based build cache (3x faster compilation)
- ✅ Debug builds with memory leak detection

### 🚧 In Progress

- 🔨 Built-in functions: `range()`, `enumerate()`, `zip()` (codegen complete, fixing memory leaks)
- 🔨 Exception handling: `try/except` (basic support, fixing edge cases)
- 🔨 Variable reassignment tracking (const vs var detection)

### 📋 Roadmap

**Phase 1: Core Completeness**
- [ ] File I/O operations
- [ ] String formatting (f-strings)
- [ ] More dict methods
- [ ] Decorators
- [ ] Generators

**Phase 2: Standard Library**
- [ ] zyth.web (HTTP server)
- [ ] zyth.http (HTTP client)
- [ ] zyth.ai (LLM integration)
- [ ] zyth.async (async/await)
- [ ] zyth.db (database connectors)

**Phase 3: Advanced**
- [ ] WebAssembly target
- [ ] Goroutines and channels
- [ ] JIT compilation
- [ ] REPL

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

**v0.1.0-alpha** - Active Development 🚧

- **Test Coverage:** 78/140 tests passing (55.7%)
- **Memory Safety:** Debug builds with automatic leak detection
- **Build Cache:** Timestamp-based compilation cache
- **Core Features:** Functions, classes, slicing, comprehensions working
- **In Progress:** Exception handling, built-in functions (range/enumerate/zip)

**Not Production Ready:**
- Limited Python compatibility (subset of language)
- Active memory leak fixes in progress
- API subject to breaking changes
- No PyPI package yet

Use for experimentation and benchmarking. Production release planned for v1.0.

## License

[Add license]

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) (coming soon)
