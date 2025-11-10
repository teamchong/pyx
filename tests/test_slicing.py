"""Test suite for list and string slicing"""
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
            pytest.fail(f"Execution failed:\nSTDOUT:\n{zy_result.stdout}\nSTDERR:\n{zy_result.stderr}")

        # Zyth outputs to stderr (Zig debug.print), Python to stdout
        zy_output = zy_result.stderr

        return py_output, zy_output


def test_list_slicing_basic():
    """Test basic list slicing: start:end"""
    code = """
nums = [1, 2, 3, 4, 5]
print(nums[1:3])
print(nums[:2])
print(nums[2:])
print(nums[:])
"""
    py_out, zy_out = run_code(code)
    assert py_out == zy_out


def test_string_slicing_basic():
    """Test basic string slicing: start:end"""
    code = """
text = "hello world"
print(text[0:5])
print(text[6:])
print(text[:5])
print(text[:])
"""
    py_out, zy_out = run_code(code)
    assert py_out == zy_out


def test_list_slicing_negative():
    """Test list slicing with negative indices"""
    code = """
nums = [1, 2, 3, 4, 5]
print(nums[-2:])
print(nums[:-2])
print(nums[-4:-1])
"""
    py_out, zy_out = run_code(code)
    assert py_out == zy_out


def test_string_slicing_negative():
    """Test string slicing with negative indices"""
    code = """
text = "hello world"
print(text[-5:])
print(text[:-6])
print(text[-11:-6])
"""
    py_out, zy_out = run_code(code)
    assert py_out == zy_out


def test_list_slicing_step():
    """Test list slicing with step parameter"""
    code = """
nums = [1, 2, 3, 4, 5, 6, 7, 8]
print(nums[::2])
print(nums[1::2])
print(nums[1:7:2])
"""
    py_out, zy_out = run_code(code)
    assert py_out == zy_out


def test_string_slicing_step():
    """Test string slicing with step parameter"""
    code = """
text = "hello world"
print(text[::2])
print(text[1::2])
print(text[0:5:2])
"""
    py_out, zy_out = run_code(code)
    assert py_out == zy_out


def test_slicing_comprehensive():
    """Test various slicing combinations"""
    code = """
nums = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
print(nums[2:7])
print(nums[:5])
print(nums[5:])
print(nums[::3])
print(nums[-3:])

text = "Python"
print(text[0:3])
print(text[2:])
print(text[:4])
print(text[::2])
print(text[-3:])
"""
    py_out, zy_out = run_code(code)
    assert py_out == zy_out


def test_empty_slice():
    """Test empty slices"""
    code = """
nums = [1, 2, 3]
print(nums[5:10])

text = "hello"
print(text[10:20])
"""
    py_out, zy_out = run_code(code)
    assert py_out == zy_out
