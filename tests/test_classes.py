"""Tests for class support"""
import subprocess
import sys
from pathlib import Path


def run_python(code: str) -> str:
    """Run Python code and return output"""
    result = subprocess.run(
        [sys.executable, "-c", code],
        capture_output=True,
        text=True,
    )
    return result.stderr + result.stdout


def run_zyth(code: str) -> str:
    """Compile and run Zyth code, return output"""
    import tempfile
    import os
    from core.compiler import compile_file

    with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as f:
        f.write(code)
        temp_file = f.name

    binary_path = None
    try:
        binary_path = compile_file(temp_file)
        result = subprocess.run([binary_path], capture_output=True, text=True)
        return result.stderr + result.stdout
    finally:
        os.unlink(temp_file)
        if binary_path and os.path.exists(binary_path):
            os.unlink(binary_path)


def test_class_definition():
    """Test basic class definition"""
    code = """
class Counter:
    def __init__(self):
        self.count = 0

c = Counter()
print(c.count)
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_instance_creation():
    """Test creating multiple instances"""
    code = """
class Counter:
    def __init__(self):
        self.count = 0

c1 = Counter()
c2 = Counter()
print(c1.count)
print(c2.count)
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_method_call():
    """Test calling instance methods"""
    code = """
class Counter:
    def __init__(self):
        self.count = 0

    def increment(self):
        self.count = self.count + 1

c = Counter()
c.increment()
print(c.count)
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_instance_variables():
    """Test accessing instance variables"""
    code = """
class Counter:
    def __init__(self):
        self.count = 0

    def get_count(self) -> int:
        return self.count

c = Counter()
print(c.get_count())
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_init_with_parameters():
    """Test __init__ with parameters"""
    code = """
class Person:
    def __init__(self, age: int):
        self.age = age

p = Person(30)
print(p.age)
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_string_fields():
    """Test class with string fields"""
    code = """
class Person:
    def __init__(self, name: str):
        self.name = name

p = Person("Alice")
print(p.name)
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_mixed_field_types():
    """Test class with both string and int fields"""
    code = """
class Person:
    def __init__(self, name: str, age: int):
        self.name = name
        self.age = age

    def greet(self):
        print(self.name)
        print(self.age)

p = Person("Alice", 30)
p.greet()
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_method_with_return():
    """Test method with return value"""
    code = """
class Calculator:
    def __init__(self, value: int):
        self.value = value

    def add(self, x: int) -> int:
        return self.value + x

calc = Calculator(10)
result = calc.add(5)
print(result)
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_multiple_methods():
    """Test class with multiple methods"""
    code = """
class Counter:
    def __init__(self):
        self.count = 0

    def increment(self):
        self.count = self.count + 1

    def decrement(self):
        self.count = self.count - 1

    def get_count(self) -> int:
        return self.count

c = Counter()
c.increment()
c.increment()
c.decrement()
print(c.get_count())
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()


def test_field_modification():
    """Test modifying instance variables"""
    code = """
class Counter:
    def __init__(self):
        self.count = 0

c = Counter()
print(c.count)
c.count = 5
print(c.count)
"""
    python_output = run_python(code)
    zyth_output = run_zyth(code)
    assert python_output.strip() == zyth_output.strip()
