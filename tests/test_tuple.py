"""Tests for tuple support"""
import subprocess
import tempfile
from pathlib import Path

import pytest

ZYTH_ROOT = Path(__file__).parent.parent


def run_zyth_code(code: str) -> str:
    """Compile and run Zyth code, return stderr output"""
    with tempfile.TemporaryDirectory() as tmpdir:
        py_file = Path(tmpdir) / "test.py"
        py_file.write_text(code)
        zy_bin = Path(tmpdir) / "test_bin"

        # Compile with zyth
        compile_result = subprocess.run(
            ['uv', 'run', 'python', '-m', 'core.compiler', str(py_file), str(zy_bin)],
            cwd=ZYTH_ROOT,
            capture_output=True,
            text=True,
            timeout=30
        )

        if compile_result.returncode != 0:
            pytest.fail(
                f"Compilation failed:\n"
                f"STDOUT:\n{compile_result.stdout}\n"
                f"STDERR:\n{compile_result.stderr}"
            )

        # Run binary
        run_result = subprocess.run(
            [str(zy_bin)],
            capture_output=True,
            text=True,
            timeout=10
        )

        if run_result.returncode != 0:
            pytest.fail(
                f"Execution failed:\n"
                f"STDOUT:\n{run_result.stdout}\n"
                f"STDERR:\n{run_result.stderr}"
            )

        return run_result.stderr


def test_tuple_basic():
    """Test basic tuple creation and access"""
    code = '''
pair = (1, 2)
print(pair[0])
print(pair[1])
'''
    output = run_zyth_code(code)
    assert output == "1\n2\n"


def test_tuple_len():
    """Test len() on tuples"""
    code = '''
pair = (1, 2)
print(len(pair))
triple = (10, 20, 30)
print(len(triple))
'''
    output = run_zyth_code(code)
    assert output == "2\n3\n"


def test_tuple_empty():
    """Test empty tuple"""
    code = '''
empty = ()
print(len(empty))
'''
    output = run_zyth_code(code)
    assert output == "0\n"


def test_tuple_multiple_elements():
    """Test tuple with many elements"""
    code = '''
nums = (1, 2, 3, 4, 5)
print(nums[0])
print(nums[2])
print(nums[4])
print(len(nums))
'''
    output = run_zyth_code(code)
    assert output == "1\n3\n5\n5\n"


def test_tuple_indexing():
    """Test tuple indexing with various indices"""
    code = '''
nums = (10, 20, 30, 40, 50)
print(nums[0])
print(nums[1])
print(nums[2])
print(nums[3])
print(nums[4])
'''
    output = run_zyth_code(code)
    assert output == "10\n20\n30\n40\n50\n"
