# NumPy-style computational benchmark
# Vector operations and nested loops

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

# Nested loop computation (matrix-like)
result = 0
for i in range(100):
    for j in range(100):
        result = result + i * j

print(result)
