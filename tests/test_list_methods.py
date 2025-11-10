"""Test suite for list methods"""
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


class TestListMethods:
    """Test all list methods"""

    @pytest.mark.parametrize("code,desc", [
        ('nums = [1, 2, 3]\nnums.append(4)\nprint(len(nums))', "append() basic"),
        ('nums = [1, 2, 3]\nnums.append(4)\nprint(nums[3])', "append() access"),
        ('nums = [1, 2, 3]\nval = nums.pop()\nprint(val)', "pop() return value"),
        ('nums = [1, 2, 3]\nnums.pop()\nprint(len(nums))', "pop() removes"),
        ('nums = [1, 2, 3]\nnums.extend([4, 5])\nprint(len(nums))', "extend() basic"),
        ('nums = [1, 2, 3]\nnums.extend([4, 5])\nprint(nums[4])', "extend() access"),
        ('nums = [1, 2, 3, 2]\nnums.remove(2)\nprint(len(nums))', "remove() basic"),
        ('nums = [1, 2, 3, 2]\nnums.remove(2)\nprint(nums[1])', "remove() first occurrence"),
        ('nums = [1, 2, 3]\nnums.reverse()\nprint(nums[0])', "reverse() basic"),
        ('nums = [1, 2, 3, 2]\nprint(nums.count(2))', "count() basic"),
        ('nums = [1, 2, 3]\nprint(nums.count(5))', "count() zero"),
        ('nums = [1, 2, 3, 4, 5]\nprint(nums.index(3))', "index() found"),
        ('nums = [5, 4, 3, 2, 1]\nprint(nums.index(1))', "index() last"),
        ('nums = [1, 2, 3]\nnums.insert(0, 0)\nprint(nums[0])', "insert() at start"),
        ('nums = [1, 2, 3]\nnums.insert(0, 0)\nprint(len(nums))', "insert() length"),
        ('nums = [1, 2, 3]\nnums.insert(1, 9)\nprint(nums[1])', "insert() middle"),
        ('nums = [1, 2, 3]\nnums.clear()\nprint(len(nums))', "clear() basic"),
        # New methods
        ('nums = [3, 1, 2]\nnums.sort()\nprint(nums[0])', "sort() ascending"),
        ('nums = [3, 1, 2]\nnums.sort()\nprint(nums[2])', "sort() last element"),
        ('nums = [1, 2, 3]\ncopy = nums.copy()\nprint(len(copy))', "copy() length"),
        ('nums = [1, 2, 3]\ncopy = nums.copy()\nprint(copy[1])', "copy() access"),
        # min/max/sum/len as methods are not Python-compatible (use built-in functions instead)
    ])
    def test_list_method(self, code, desc):
        """Test list methods match Python behavior"""
        py_out, zy_out = run_code(code)
        assert py_out == zy_out, f"{desc}: Python={py_out!r}, Zyth={zy_out!r}"

    def test_list_chaining(self):
        """Test chaining multiple list operations"""
        code = '''
nums = [1, 2, 3]
nums.append(4)
nums.extend([5, 6])
nums.insert(0, 0)
nums.reverse()
print(len(nums))
print(nums[0])
'''
        py_out, zy_out = run_code(code)
        assert py_out == zy_out

    def test_list_comprehension_with_methods(self):
        """Test list comprehensions work with methods"""
        code = '''
nums = [1, 2, 3, 4, 5]
squares = [x * x for x in nums]
print(len(squares))
print(squares[0])
'''
        py_out, zy_out = run_code(code)
        assert py_out == zy_out


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
