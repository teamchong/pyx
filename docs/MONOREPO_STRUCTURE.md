# Zyth Monorepo Structure Proposal

## Root Directory (CLEAN - config files only)

```
zyth/
├── packages/               # All code lives here
├── examples/               # Example programs
├── docs/                   # Documentation
├── .github/                # CI/CD
├── pyproject.toml          # Root workspace config
├── Makefile                # Dev commands
├── .gitignore
├── README.md
└── ARCHITECTURE.md
```

**NO binaries, NO src/, NO build artifacts in root!**

## Packages Structure

```
packages/
├── core/                   # @zyth/core - Compiler
│   ├── pyproject.toml
│   ├── zyth_core/
│   │   ├── parser.py
│   │   ├── typechecker.py
│   │   ├── codegen.py
│   │   └── optimizer.py
│   └── tests/
│
├── runtime/                # @zyth/runtime - Zig runtime
│   ├── pyproject.toml
│   ├── build.zig
│   ├── src/
│   │   ├── runtime.zig
│   │   ├── gc.zig
│   │   ├── types.zig
│   │   └── ffi.zig
│   └── tests/
│
├── cli/                    # @zyth/cli - CLI tool
│   ├── pyproject.toml
│   ├── zyth_cli/
│   │   └── main.py
│   └── tests/
│
├── web/                    # zyth.web - Web framework (INDEPENDENT)
│   ├── pyproject.toml
│   ├── build.zig
│   ├── src/
│   │   ├── app.zig
│   │   ├── routing.zig
│   │   └── middleware.zig
│   ├── zyth_web/           # Python stubs for typing
│   │   └── __init__.pyi
│   └── tests/
│
├── http/                   # zyth.http - HTTP client (INDEPENDENT)
│   ├── pyproject.toml
│   ├── build.zig
│   ├── src/
│   │   ├── client.zig
│   │   └── server.zig
│   └── tests/
│
├── ai/                     # zyth.ai - ML/AI (INDEPENDENT)
│   ├── pyproject.toml
│   ├── build.zig
│   ├── src/
│   │   ├── tensor.zig
│   │   └── numpy_compat.zig
│   └── tests/
│
├── async/                  # zyth.async - Async runtime (INDEPENDENT)
│   ├── pyproject.toml
│   ├── build.zig
│   ├── src/
│   │   ├── goroutine.zig
│   │   └── channel.zig
│   └── tests/
│
├── db/                     # zyth.db - Database drivers (INDEPENDENT)
│   ├── pyproject.toml
│   ├── build.zig
│   ├── src/
│   │   ├── postgres.zig
│   │   ├── mysql.zig
│   │   └── sqlite.zig
│   └── tests/
│
├── json/                   # zyth.json - JSON (INDEPENDENT)
│   └── ...
│
└── crypto/                 # zyth.crypto - Crypto (INDEPENDENT)
    └── ...
```

## Benefits

1. **Independent versioning**: `zyth.web@1.0.0`, `zyth.ai@2.3.1`
2. **Independent releases**: Ship `zyth.web` without touching `zyth.ai`
3. **Selective installation**: `pip install zyth-web` (not entire stdlib)
4. **Clear ownership**: Each package has own maintainers
5. **Parallel development**: Teams work on separate packages

## Package Naming

**Python packages:**
- PyPI: `zyth-web`, `zyth-ai`, `zyth-http`
- Import: `from zyth.web import App`

**Zig modules:**
- Located in `packages/web/src/`
- Built separately with `zig build`

## Example Usage

```python
# User installs only what they need
pip install zyth-cli zyth-web

# Code
from zyth.web import App

app = App()

@app.get("/")
def index():
    return {"msg": "Hello"}
```

## Does this structure work for you?
