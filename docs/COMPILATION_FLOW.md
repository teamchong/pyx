# Zyth Compilation Flow

## High-Level Overview

```
Python Source → Python Compiler → Zig Code → Zig Compiler → Native Binary
    (.py)          (Python)        (.zig)       (Zig)          (exe)
```

## Detailed Flow

### 1. **Python Compiler** (packages/compiler/)

**Language:** Pure Python
**Input:** Python source code (.py)
**Output:** Zig source code (.zig)

```python
# Input: fibonacci.py
def fibonacci(n: int) -> int:
    if n <= 1:
        return n
    return fibonacci(n-1) + fibonacci(n-2)
```

**Components:**
- `parser.py` - Parse Python AST
- `typechecker.py` - Infer types
- `codegen.py` - Generate Zig code

```zig
// Output: fibonacci.zig
const std = @import("std");
const runtime = @import("zyth_runtime");

fn fibonacci(n: i64) i64 {
    if (n <= 1) {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
}

pub fn main() void {
    const result = fibonacci(10);
    std.debug.print("{}\n", .{result});
}
```

### 2. **Zig Runtime** (packages/runtime/zig/)

**Language:** Pure Zig
**Purpose:** Provide Python runtime support in compiled code

```zig
// runtime.zig - Core types
pub const PyObject = struct { ... };
pub const PyInt = struct { ... };
pub const PyList = struct { ... };
pub const PyDict = struct { ... };

// gc.zig - Garbage collection
pub fn incref(obj: *PyObject) void { ... }
pub fn decref(obj: *PyObject) void { ... }
```

**When used:**
```zig
// Generated code when using Python types
const list = try PyList.create(allocator);
try list.append(PyInt.create(allocator, 42));
```

### 3. **Zig Standard Library** (packages/stdlib/zig/)

**Language:** Pure Zig
**Purpose:** Implement `zyth.web`, `zyth.http`, etc.

```zig
// packages/stdlib/zig/web.zig
pub const App = struct {
    routes: std.StringHashMap(Route),

    pub fn get(self: *App, path: []const u8, handler: Handler) !void {
        try self.routes.put(path, .{ .handler = handler });
    }
};
```

**Python usage:**
```python
from zyth.web import App

app = App()

@app.get("/")
def index():
    return {"msg": "Hello"}
```

**Generated Zig:**
```zig
const web = @import("zyth_stdlib").web;

pub fn main() !void {
    var app = web.App.init(allocator);
    try app.get("/", index);
    try app.run();
}
```

### 4. **Zig Compiler** (system)

**Language:** Zig itself
**Input:** Generated .zig + runtime + stdlib
**Output:** Native executable

```bash
zig build-exe generated.zig \
    --pkg-path zyth_runtime packages/runtime/zig \
    --pkg-path zyth_stdlib packages/stdlib/zig \
    -O ReleaseFast
```

## Complete Example

### Input: app.py
```python
from zyth.web import App

app = App()

@app.get("/hello")
def hello():
    return {"message": "Hello from Zyth!"}

if __name__ == "__main__":
    app.run(port=8000)
```

### Step 1: Python Compiler Generates

**File:** `/tmp/zyth_build/app.zig`
```zig
const std = @import("std");
const runtime = @import("zyth_runtime");
const web = @import("zyth_stdlib").web;

pub fn hello() web.Response {
    var obj = runtime.PyDict.create(allocator);
    obj.set("message", runtime.PyString.create("Hello from Zyth!"));
    return web.Response.fromPyObject(obj);
}

pub fn main() !void {
    var app = web.App.init(allocator);
    try app.get("/hello", hello);
    try app.run(.{ .port = 8000 });
}
```

### Step 2: Zig Compiles with Runtime

```bash
zig build-exe /tmp/zyth_build/app.zig \
    --pkg-path zyth_runtime packages/runtime/zig \
    --pkg-path zyth_stdlib packages/stdlib/zig \
    -O ReleaseFast \
    -o app_binary
```

### Step 3: Run Native Binary

```bash
./app_binary
# Server running on http://localhost:8000
```

## Directory Structure

```
zyth/
├── packages/
│   ├── compiler/              # 🐍 Python - Generates Zig
│   │   └── zyth_compiler/
│   │       ├── parser.py
│   │       ├── codegen.py
│   │       └── compiler.py    # Orchestrates Zig compilation
│   │
│   ├── runtime/               # 🔶 Zig - Runtime support
│   │   ├── zig/
│   │   │   ├── build.zig
│   │   │   ├── runtime.zig    # Core types
│   │   │   ├── gc.zig         # GC
│   │   │   └── types.zig      # PyObject, PyList, etc
│   │   └── zyth_runtime/      # Python wrapper (thin)
│   │
│   ├── stdlib/                # 🔶 Zig - Standard lib
│   │   ├── zig/
│   │   │   ├── web.zig
│   │   │   ├── http.zig
│   │   │   └── ai.zig
│   │   └── zyth_stdlib/       # Python stubs for IDE
│   │
│   └── cli/                   # 🐍 Python - User interface
│       └── zyth_cli/
│           └── main.py
│
└── examples/
    └── fibonacci.py           # Python source
```

## Summary

- **Python** = Compiler + tooling (developer-facing)
- **Zig** = Runtime + stdlib + generated code (user code compiles to this)
- **Result** = Fast native binary with no Python interpreter needed
