"""Test that dict.items() returns tuples"""
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


def test_dict_items_returns_tuples():
    """Test that dict.items() returns list of tuples"""
    code = '''
d = {"x": 10, "y": 20}
items = d.items()
# Access tuple elements (test integer values, not strings due to print limitation)
first = items[0]
print(first[1])  # value from first tuple
second = items[1]
print(second[1])  # value from second tuple
'''
    output = run_zyth_code(code)
    # Dict iteration order may vary, but values should be 10 and 20
    values = [int(line) for line in output.strip().split('\n')]
    assert sorted(values) == [10, 20]


def test_dict_items_tuple_len():
    """Test that dict.items() tuples have length 2"""
    code = '''
d = {"a": 1}
items = d.items()
pair = items[0]
print(len(pair))
'''
    output = run_zyth_code(code)
    assert output == "2\n"


def test_dict_items_list_len():
    """Test that dict.items() returns list with correct length"""
    code = '''
d = {"a": 1, "b": 2, "c": 3}
items = d.items()
print(len(items))
'''
    output = run_zyth_code(code)
    assert output == "3\n"


def test_dict_items_access_integers():
    """Test accessing integer values from dict.items() tuples"""
    code = '''
d = {"num": 42}
items = d.items()
pair = items[0]
value = pair[1]
print(value)
'''
    output = run_zyth_code(code)
    assert output == "42\n"
