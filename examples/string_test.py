"""
Simple string concatenation test
"""

def greet(name: str) -> str:
    greeting = "Hello, "
    return greeting + name

result = greet("World")
print(result)
