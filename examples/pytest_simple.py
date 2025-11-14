# Simple pytest-style test demonstrations
# Tests basic operations work without complex assertions

print("Running basic operation tests...")

# Test 1: List append
test_name = "test_list_append"
my_list = [1, 2, 3]
my_list.append(4)
my_list.append(5)
print(test_name + ": PASS - list now has")
print(len(my_list))
print("elements")

# Test 2: List pop
test_name = "test_list_pop"
numbers = [10, 20, 30, 40, 50]
val = numbers.pop()
print(test_name + ": PASS - list now has")
print(len(numbers))
print("elements")

# Test 3: String upper
test_name = "test_string_upper"
text = "hello world"
upper_text = text.upper()
print(test_name + ": PASS - uppercase:")
print(upper_text)

# Test 4: String lower
test_name = "test_string_lower"
text2 = "HELLO WORLD"
lower_text = text2.lower()
print(test_name + ": PASS - lowercase:")
print(lower_text)

# Test 5: String strip
test_name = "test_string_strip"
padded = "  hello  "
stripped = padded.strip()
print(test_name + ": PASS - stripped:")
print(stripped)

# Test 6: String split
test_name = "test_string_split"
sentence = "one two three four"
words = sentence.split(" ")
print(test_name + ": PASS - split into")
print(len(words))
print("words")

# Test 7: Arithmetic
test_name = "test_arithmetic"
a = 100
b = 50
sum_result = a + b
diff_result = a - b
prod_result = a * b
print(test_name + ": PASS - results:")
print(sum_result)
print(diff_result)
print(prod_result)

# Test 8: Loops
test_name = "test_loop_sum"
total = 0
for i in range(100):
    total = total + i
print(test_name + ": PASS - sum is")
print(total)

print("All basic tests completed!")
