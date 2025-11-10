# Comprehensive test of all built-in methods

# STRING METHODS
print("=== STRING METHODS ===")
text = "hello world hello"

# split, upper, lower
parts = text.split(" ")
print("Split length:")
print(len(parts))

upper_text = text.upper()
print("Upper length:")
print(len(upper_text))

# startswith, endswith
if text.startswith("hello"):
    print("Starts with hello: YES")

if text.endswith("world"):
    print("Ends with world: NO")

# find, count
pos = text.find("world")
print("Find 'world' at:")
print(pos)

count = text.count("hello")
print("Count 'hello':")
print(count)

# replace, strip
replaced = text.replace("hello", "hi")
print("Replace length:")
print(len(replaced))

padded = "  trim  "
trimmed = padded.strip()
print("Strip length:")
print(len(trimmed))

# LIST METHODS
print("=== LIST METHODS ===")
numbers = [1, 2, 3, 4, 5]

# append, extend
numbers.append(6)
more = [7, 8]
numbers.extend(more)
print("After append and extend:")
print(len(numbers))

# count, index
count_3 = numbers.count(3)
print("Count of 3:")
print(count_3)

index_5 = numbers.index(5)
print("Index of 5:")
print(index_5)

# insert, reverse
numbers.insert(0, 0)
print("After insert at 0:")
print(numbers[0])

numbers.reverse()
print("After reverse, first:")
print(numbers[0])

# remove
numbers.remove(8)
print("After remove(8), length:")
print(len(numbers))

# DICT METHODS
print("=== DICT METHODS ===")
person = {"name": "Alice", "age": 30, "city": "NYC"}

# keys, values
all_keys = person.keys()
all_values = person.values()
print("Keys and values length:")
print(len(all_keys))
print(len(all_values))

# LIST COMPREHENSIONS
print("=== LIST COMPREHENSIONS ===")
source_nums = [1, 2, 3, 4, 5]
squares = [x * x for x in source_nums]
print("Squares length:")
print(len(squares))

evens = [x for x in numbers if x > 4]
print("Filtered evens length:")
print(len(evens))

# 'IN' OPERATOR
print("=== IN OPERATOR ===")
if 3 in numbers:
    print("3 in numbers: YES")

if "name" in person:
    print("name in person: YES")

if "world" in text:
    print("world in text: YES")

# SLICING
print("=== SLICING ===")
slice_list = numbers[2:5]
slice_str = text[0:5]
print(len(slice_list))
print(len(slice_str))
print("Slicing works: YES")

print("=== ALL TESTS PASSED ===")
