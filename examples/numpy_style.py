# NumPy-style computational example
# Demonstrates PyX's computational performance advantages
# Pure Python - no imports, no functions, no classes

print("Starting computational benchmarks...")

# Vector dot product using loops
print("Computing dot product...")
n = 10000
dot_product = 0
for i in range(n):
    # Simulating two vectors with computed values
    a_i = i * 2
    b_i = i + 100
    dot_product = dot_product + a_i * b_i

print("Dot product result:")
print(dot_product)

# Sum of squares
print("Computing sum of squares...")
sum_squares = 0
for i in range(n):
    sum_squares = sum_squares + i * i

print("Sum of squares:")
print(sum_squares)

# Element-wise operations (simulated without lists)
print("Computing element-wise operations...")
total_add = 0
total_mul = 0
for i in range(n):
    a = i * 2
    b = i + 100
    total_add = total_add + (a + b)
    total_mul = total_mul + (a * b)

print("Total addition:")
print(total_add)
print("Total multiplication:")
print(total_mul)

# Nested loop computation (simulating matrix operations)
print("Computing nested loops...")
result = 0
for i in range(100):
    for j in range(100):
        result = result + i * j

print("Nested loop result:")
print(result)

print("All computations complete!")
