"""
Zyth Core Types Demo
Tests: strings, lists, dicts
"""

def test_strings() -> None:
    # String literals
    s1 = "hello"
    s2 = "world"

    # String concatenation
    s3 = s1 + " " + s2
    print(s3)  # "hello world"

    # String methods
    upper = s1.upper()
    print(upper)  # "HELLO"

    lower = "WORLD".lower()
    print(lower)  # "world"

    # String length
    length = len(s1)
    print(length)  # 5


def test_lists() -> None:
    # List literals
    nums = [1, 2, 3, 4, 5]

    # List access
    first = nums[0]
    print(first)  # 1

    # List methods
    nums.append(6)
    print(len(nums))  # 6

    last = nums.pop()
    print(last)  # 6
    print(len(nums))  # 5

    # List iteration
    total = 0
    for n in nums:
        total = total + n
    print(total)  # 15

    # List comprehension (basic)
    doubled = [n * 2 for n in nums]
    print(len(doubled))  # 5
    print(doubled[0])  # 2
    print(doubled[4])  # 10


def test_dicts() -> None:
    # Dict literals
    person = {"name": "Alice", "age": 30}

    # Dict access
    name = person["name"]
    print(name)  # "Alice"

    age = person["age"]
    print(age)  # 30

    # Dict assignment
    person["city"] = "NYC"

    # Dict methods
    has_name = "name" in person
    print(has_name)  # 1 (true)

    has_email = "email" in person
    print(has_email)  # 0 (false)

    # Dict length
    size = len(person)
    print(size)  # 3


def main() -> None:
    print("=== Testing Strings ===")
    test_strings()

    print("\n=== Testing Lists ===")
    test_lists()

    print("\n=== Testing Dicts ===")
    test_dicts()

    print("\nAll tests passed!")


main()
