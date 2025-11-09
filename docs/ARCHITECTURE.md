# Zyth Monorepo Architecture

## Language Breakdown

**Python Components:**
- Compiler (parser, type inference, codegen)
- CLI tool
- Build tooling

**Zig Components:**
- Runtime library (GC, types, memory)
- Standard library (zyth.web, zyth.http, etc)
- Generated code from Python

## Structure

```
zyth/
├── packages/
│   ├── compiler/          # zyth-compiler
│   │   ├── zyth_compiler/
│   │   │   ├── __init__.py
│   │   │   ├── parser.py       # Python AST → IR
│   │   │   ├── typechecker.py  # Type inference engine
│   │   │   ├── codegen.py      # IR → Zig code
│   │   │   └── optimizer.py    # Optimization passes
│   │   ├── tests/
│   │   └── pyproject.toml
│   │
│   ├── runtime/           # zyth-runtime
│   │   ├── zyth_runtime/
│   │   │   └── __init__.py
│   │   ├── zig/               # Zig runtime code
│   │   │   ├── runtime.zig    # Core runtime
│   │   │   ├── gc.zig         # Garbage collector
│   │   │   ├── ffi.zig        # Python FFI bridge
│   │   │   └── types.zig      # Python types in Zig
│   │   ├── tests/
│   │   └── pyproject.toml
│   │
│   ├── stdlib/            # zyth-stdlib
│   │   ├── zyth_stdlib/
│   │   │   ├── __init__.py
│   │   │   ├── web/          # zyth.web
│   │   │   ├── http/         # zyth.http
│   │   │   ├── ai/           # zyth.ai
│   │   │   ├── async/        # zyth.async
│   │   │   ├── db/           # zyth.db
│   │   │   └── ...
│   │   ├── tests/
│   │   └── pyproject.toml
│   │
│   └── cli/               # zyth-cli
│       ├── zyth_cli/
│       │   ├── __init__.py
│       │   ├── main.py       # CLI entrypoint
│       │   ├── commands/     # Subcommands
│       │   │   ├── run.py
│       │   │   ├── build.py
│       │   │   ├── test.py
│       │   │   └── serve.py
│       │   └── utils.py
│       ├── tests/
│       └── pyproject.toml
│
├── examples/              # Example Zyth programs
│   ├── fibonacci.py
│   ├── web_server.py
│   └── ml_inference.py
│
├── docs/                  # Documentation
│   ├── getting-started.md
│   ├── api-reference.md
│   └── contributing.md
│
├── .github/
│   └── workflows/
│       ├── ci.yml
│       ├── release.yml
│       └── benchmarks.yml
│
├── pyproject.toml         # Workspace root
├── uv.lock
└── README.md
```

## Package Dependencies

```
zyth-cli
  └─> zyth-compiler
  └─> zyth-runtime
  └─> zyth-stdlib
        └─> zyth-runtime

zyth-compiler (no internal deps)
zyth-runtime (no internal deps)
```

## Development Workflow

```bash
# Install all packages in workspace
uv sync

# Run from CLI package
uv run zyth examples/fibonacci.py

# Run tests for specific package
uv run pytest packages/compiler/tests

# Run all tests
uv run pytest

# Type check
uv run mypy packages/

# Format code
uv run ruff format packages/
```

## CLI Commands (Future)

```bash
zyth run app.py              # Run Python file
zyth build app.py            # Build binary
zyth test                    # Run tests
zyth serve                   # Dev server with hot reload
zyth deploy                  # Deploy to Zyth Cloud
zyth add requests            # Add dependency
zyth benchmark              # Run benchmarks
```

## Standard Library Modules

See `packages/stdlib/README.md` for full list of `zyth.*` modules.
