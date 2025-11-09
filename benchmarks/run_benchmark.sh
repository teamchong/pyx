#!/bin/bash
# Benchmark runner - compares Python vs Zyth performance

ITERATIONS=100000

echo "=== String Concatenation Benchmark ==="
echo "Iterations: $ITERATIONS"
echo ""

# Benchmark Python
echo "Python (CPython):"
time for i in $(seq 1 $ITERATIONS); do
    python benchmarks/string_concat.py > /dev/null
done

echo ""

# Benchmark Zyth
echo "Zyth (compiled):"
time for i in $(seq 1 $ITERATIONS); do
    benchmarks/string_concat_zyth > /dev/null
done
