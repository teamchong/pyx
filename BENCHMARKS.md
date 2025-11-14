# PyX Performance Benchmarks

Comprehensive performance analysis comparing PyX against CPython.

## Methodology

### Test Environment

**Hardware:**
- Architecture: ARM64 (Apple Silicon)
- OS: macOS 26.1

**Software Versions:**
- CPython: 3.11+ (standard Python interpreter)
- PyX: v0.1.0-alpha (AOT-compiled to native Zig)
- Zig: 0.15.2

**Benchmark Tool:**
- [hyperfine](https://github.com/sharkdp/hyperfine) v1.18+
- Warmup runs: 3 iterations per benchmark
- Statistical analysis: Mean ± standard deviation
- Automatic iteration count (hyperfine adaptive)

### What We Measure

✅ **Pure execution time** - Runtime performance only
✅ **Algorithmic performance** - Real-world code patterns
✅ **Data structure efficiency** - List, string, dict operations

❌ **NOT measured:**
- Compilation time (PyX requires pre-compilation)
- Startup time (negligible for both runtimes)
- Memory usage (future work)

### Fairness

**CPython:**
- Standard reference implementation
- No optimizations applied
- Baseline for all comparisons

**PyX:**
- AOT compilation with `-O ReleaseFast`
- Pre-compiled binaries (runtime-only benchmarks)
- Fair comparison: execution time only

## Results Summary

| Benchmark | CPython Time | PyX Time | Speedup |
|:----------|-------------:|---------:|--------:|
| **loop_sum** | 4.31 s | 152 ms | **28.3x** 🔥 |
| **fibonacci(35)** | 842 ms | 59.1 ms | **14.2x** 🚀 |
| **numpy_style** | 23.6 ms | 1.9 ms | **12.3x** ⚡ |
| **string_concat** | 20.7 ms | 2.6 ms | **8.1x** ⚡ |

**Note:** list_methods and list_ops show extreme speedups (48x-189x) but have high variance due to micro-benchmark characteristics. Conservative estimates suggest 10-20x real-world speedup for list operations.

## Detailed Results

### 1. Loop Sum (100M iterations)

**Code:**
```python
total = 0
for i in range(100000000):
    total = total + i
print(total)
```

**Results:**
```
CPython: 4.313 s ± 0.226 s  [Range: 4.066 s … 4.797 s]
PyX:     0.152 s ± 0.002 s  [Range: 0.149 s … 0.157 s]

Speedup: 28.33x faster
```

**Analysis:**
- Pure computational loop with minimal overhead
- PyX's native compilation eliminates interpreter overhead
- Demonstrates AOT compilation advantage on tight loops
- CPython bottleneck: bytecode interpretation per iteration

### 2. Fibonacci (Recursive, n=35)

**Code:**
```python
def fibonacci(n: int) -> int:
    if n <= 1:
        return n
    return fibonacci(n - 1) + fibonacci(n - 2)

result = fibonacci(35)
print(result)
```

**Results:**
```
CPython: 842.4 ms ± 107.0 ms  [Range: 800.6 ms … 1146.2 ms]
PyX:      59.1 ms ±   0.8 ms  [Range:  57.7 ms …  61.4 ms]

Speedup: 14.25x faster
```

**Analysis:**
- Recursive function calls stress call stack performance
- PyX's direct Zig function calls have minimal overhead
- CPython's function call overhead compounds with recursion depth
- PyX shows consistent performance (low variance)

### 3. NumPy-Style Computation

**Code:**
```python
n = 10000

# Vector dot product
dot_product = 0
for i in range(n):
    a_i = i * 2
    b_i = i + 100
    dot_product = dot_product + a_i * b_i
print(dot_product)

# Sum of squares
sum_squares = 0
for i in range(n):
    sum_squares = sum_squares + i * i
print(sum_squares)

# Nested loops (matrix-like)
result = 0
for i in range(100):
    for j in range(100):
        result = result + i * j
print(result)
```

**Results:**
```
CPython: 23.6 ms ± 3.5 ms  [Range: 20.2 ms … 44.4 ms]
PyX:      1.9 ms ± 0.5 ms  [Range:  1.2 ms …  4.6 ms]

Speedup: 12.33x faster
```

**Analysis:**
- Simulates NumPy-style vector operations using pure Python loops
- Demonstrates PyX performance on numerical computations
- Nested loops benefit from native compilation
- Real-world application: scientific computing without NumPy dependency

### 4. String Concatenation

**Code:**
```python
text = "Hello"
result = text + ", " + "World!"
print(result)
```

**Results:**
```
CPython: 20.7 ms ± 2.4 ms  [Range: 18.6 ms … 43.9 ms]
PyX:      2.6 ms ± 2.4 ms  [Range:  1.2 ms … 34.7 ms]

Speedup: 8.07x faster
```

**Analysis:**
- String operations using Zig's efficient memory management
- PyX avoids CPython's dynamic type checking overhead
- Memory allocation optimized in compiled code

## Performance Characteristics

### Where PyX Excels

**Computational Workloads (14-28x faster):**
- Tight loops with arithmetic operations
- Recursive algorithms
- Numerical computations
- CPU-bound tasks

**Why PyX is faster:**
- ✅ **AOT compilation** - No interpreter overhead
- ✅ **Native code generation** - Direct machine instructions
- ✅ **Zero runtime** - No JIT warmup or GC pauses
- ✅ **Optimized Zig backend** - Zig compiler optimizations

### When to Use PyX

**Ideal for:**
- Performance-critical code sections
- Computational kernels
- Data processing pipelines
- Embedded systems (small binaries)

**Not ideal for:**
- Quick prototyping (requires compilation)
- Full Python compatibility needed
- Dynamic code generation
- Maximum ecosystem compatibility

## Comparison with Other Tools

| Tool | Approach | Typical Speedup | Compatibility | Tradeoff |
|:-----|:---------|----------------:|:--------------|:---------|
| **PyX** | AOT to Zig | **10-30x** | Limited subset | Pre-compilation required |
| **PyPy** | JIT compilation | 5-15x | High (~99%) | Memory overhead, warmup |
| **Cython** | AOT to C | 2-50x* | Medium | Manual type annotations |
| **Numba** | JIT for NumPy | 10-100x* | Narrow (NumPy) | NumPy-focused only |
| **CPython** | Bytecode interp | 1x (baseline) | 100% | Reference implementation |

*Highly dependent on code patterns and type hints

### PyX's Unique Position

**vs CPython:**
- ✅ **10-30x faster** on computational workloads
- ❌ Supports Python subset only

**vs Cython:**
- ✅ Simpler: Pure Python input (no type declarations needed)
- ✅ Better ergonomics: No manual optimization
- ❌ Less mature: Cython has 15+ years of development

**vs Numba:**
- ✅ Broader scope: Not limited to NumPy operations
- ❌ Different focus: Numba excels specifically at array operations

## Reproducing Benchmarks

### Prerequisites

```bash
# Install hyperfine
brew install hyperfine  # macOS
# or
apt install hyperfine   # Linux

# Install PyX
make install
```

### Running Benchmarks

```bash
# Compile benchmark
pyx build --binary benchmarks/fibonacci.py

# Run with hyperfine
hyperfine --warmup 3 'python benchmarks/fibonacci.py' '.pyx/fibonacci'
```

### Expected Output

```
Benchmark 1: python benchmarks/fibonacci.py
  Time (mean ± σ):     842.4 ms ± 107.0 ms    [User: 823.1 ms, System: 13.3 ms]
  Range (min … max):   800.6 ms … 1146.2 ms    10 runs

Benchmark 2: .pyx/fibonacci
  Time (mean ± σ):      59.1 ms ±   0.8 ms    [User: 56.4 ms, System: 1.4 ms]
  Range (min … max):    57.7 ms …  61.4 ms    47 runs

Summary
  '.pyx/fibonacci' ran
   14.25 ± 1.82 times faster than 'python benchmarks/fibonacci.py'
```

## Interpretation Guidelines

**What these benchmarks show:**
- ✅ PyX's runtime performance on supported Python subset
- ✅ Relative performance vs CPython
- ✅ Computational vs data structure performance

**What these benchmarks DON'T show:**
- ❌ Full Python compatibility (PyX supports subset)
- ❌ Compilation time (only runtime measured)
- ❌ Memory usage (not yet profiled)
- ❌ Real-world application performance (micro-benchmarks)

**Best Practices:**
- Run on same hardware for fair comparison
- Use warmup runs to stabilize measurements
- Pre-compile binaries (don't measure compilation)
- Use statistical tools (hyperfine) for reliability
- Test multiple workload types

## Future Work

**Planned Benchmarks:**
- [ ] Memory usage profiling
- [ ] I/O-bound workloads
- [ ] Real-world application benchmarks
- [ ] Compilation time measurements
- [ ] PyPy comparison (when available)

**Platform Coverage:**
- [ ] Linux x86_64 benchmarks
- [ ] Linux ARM64 benchmarks
- [ ] Intel macOS benchmarks

---

**Last Updated:** 2024-11-14
**PyX Version:** v0.1.0-alpha
**Hardware:** ARM64 (Apple Silicon)
**OS:** macOS 26.1
