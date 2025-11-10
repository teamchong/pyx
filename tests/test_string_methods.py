"""Test suite for string methods"""
import pytest
import subprocess
import tempfile
import os
from pathlib import Path

ZYTH_ROOT = Path(__file__).parent.parent
COMPILER = ZYTH_ROOT / "packages" / "core" / "zyth_core" / "compiler.py"


def run_code(code: str) -> tuple[str, str]:
    """Run code in both Python and Zyth, return (py_output, zy_output)"""
    with tempfile.TemporaryDirectory() as tmpdir:
        py_file = os.path.join(tmpdir, "test.py")
        zy_bin = os.path.join(tmpdir, "test_zy")

        # Write Python code
        with open(py_file, "w") as f:
            f.write(code)

        # Run Python
        py_result = subprocess.run(
            ["python", py_file],
            capture_output=True,
            text=True,
            timeout=5
        )
        py_output = py_result.stdout

        # Compile and run Zyth
        compile_result = subprocess.run(
            ["uv", "run", "python", "-m", "core.compiler", py_file, zy_bin],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=ZYTH_ROOT
        )

        if compile_result.returncode != 0:
            pytest.fail(f"Compilation failed:\nSTDOUT:\n{compile_result.stdout}\nSTDERR:\n{compile_result.stderr}")

        zy_result = subprocess.run(
            [zy_bin],
            capture_output=True,
            text=True,
            timeout=5
        )

        if zy_result.returncode != 0:
            pytest.fail(f"Zyth execution failed (exit {zy_result.returncode}):\nSTDOUT:\n{zy_result.stdout}\nSTDERR:\n{zy_result.stderr}")

        # Zyth uses std.debug.print() which writes to stderr
        zy_output = zy_result.stderr

        return py_output, zy_output


class TestStringMethods:
    """Test all string methods"""

    @pytest.mark.parametrize("code,desc", [
        ('text = "hello"\nprint(text.upper())', "upper()"),
        ('text = "HELLO"\nprint(text.lower())', "lower()"),
        ('text = "  hello  "\nprint(len(text.strip()))', "strip()"),
        ('text = "hello world"\nprint(len(text.split(" ")))', "split() basic"),
        ('text = "a,b,c"\nparts = text.split(",")\nprint(parts[0])', "split() access"),
        ('text = "hello"\nprint(text.replace("l", "L"))', "replace()"),
        ('text = "hello world"\nif text.startswith("hello"):\n    print("YES")', "startswith() true"),
        ('text = "hello world"\nif text.startswith("world"):\n    print("YES")\nelse:\n    print("NO")', "startswith() false"),
        ('text = "hello world"\nif text.endswith("world"):\n    print("YES")', "endswith() true"),
        ('text = "hello world"\nif text.endswith("hello"):\n    print("YES")\nelse:\n    print("NO")', "endswith() false"),
        ('text = "hello world"\nprint(text.find("world"))', "find() found"),
        ('text = "hello world"\nprint(text.find("xyz"))', "find() not found"),
        ('text = "hello hello"\nprint(text.count("hello"))', "count() multiple"),
        ('text = "abcabc"\nprint(text.count("bc"))', "count() substring"),
        ('text = "hello"\nprint(text.count("x"))', "count() zero"),
        # New methods
        ('words = ["hello", "world"]\nprint(",".join(words))', "join()"),
        ('text = "12345"\nif text.isdigit():\n    print("YES")', "isdigit() true"),
        ('text = "123a"\nif text.isdigit():\n    print("YES")\nelse:\n    print("NO")', "isdigit() false"),
        ('text = "hello"\nif text.isalpha():\n    print("YES")', "isalpha() true"),
        ('text = "hello123"\nif text.isalpha():\n    print("YES")\nelse:\n    print("NO")', "isalpha() false"),
        ('text = "hello world"\nprint(text.capitalize())', "capitalize()"),
        ('text = "HeLLo"\nprint(text.swapcase())', "swapcase()"),
        ('text = "hello world"\nprint(text.title())', "title()"),
        ('text = "hi"\nprint(text.center(6))', "center()"),
    ])
    def test_string_method(self, code, desc):
        """Test string methods match Python behavior"""
        py_out, zy_out = run_code(code)
        assert py_out == zy_out, f"{desc}: Python={py_out!r}, Zyth={zy_out!r}"

    def test_string_count_vs_list_count(self):
        """Test that count() dispatches correctly based on type"""
        code = '''
text = "hello hello"
print(text.count("hello"))
numbers = [1, 2, 3, 2]
print(numbers.count(2))
'''
        py_out, zy_out = run_code(code)
        assert py_out == zy_out
        assert "2\n2\n" in py_out  # Verify correct counts (2 hellos in string, 2 twos in list)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
