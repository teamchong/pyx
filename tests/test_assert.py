"""Test suite for assert statements"""
import subprocess
import tempfile
import os
from pathlib import Path

ZYTH_ROOT = Path(__file__).parent.parent


def run_code(code: str) -> tuple[str, str, int, int]:
    """Run code in both Python and Zyth, return (py_output, zy_output, py_exit, zy_exit)"""
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
        py_output = py_result.stdout + py_result.stderr
        py_exit = py_result.returncode

        # Compile and run Zyth
        compile_result = subprocess.run(
            ["uv", "run", "python", "-m", "core.compiler", py_file, zy_bin],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=ZYTH_ROOT
        )

        if compile_result.returncode != 0:
            raise RuntimeError(f"Compilation failed:\nSTDOUT:\n{compile_result.stdout}\nSTDERR:\n{compile_result.stderr}")

        zy_result = subprocess.run(
            [zy_bin],
            capture_output=True,
            text=True,
            timeout=5
        )

        # Zyth writes to stderr (std.debug.print)
        zy_output = zy_result.stderr + zy_result.stdout
        zy_exit = zy_result.returncode

        return py_output, zy_output, py_exit, zy_exit


def test_assert_true():
    """Test assertion that passes"""
    code = """
x = 5
assert x == 5
assert x > 0
assert x < 10
print("All assertions passed")
"""
    py_out, zy_out, py_exit, zy_exit = run_code(code)

    assert py_exit == 0, f"Python exited with code {py_exit}"
    assert zy_exit == 0, f"Zyth exited with code {zy_exit}"
    assert "All assertions passed" in py_out
    assert "All assertions passed" in zy_out


def test_assert_false():
    """Test assertion that fails"""
    code = """
x = 5
assert x == 10
print("This should not print")
"""
    py_out, zy_out, py_exit, zy_exit = run_code(code)

    # Both should fail with non-zero exit
    assert py_exit != 0, f"Python should have failed but exited with code {py_exit}"
    assert zy_exit != 0, f"Zyth should have failed but exited with code {zy_exit}"

    # Both should print AssertionError
    assert "AssertionError" in py_out
    assert "AssertionError" in zy_out

    # Neither should print the success message
    assert "This should not print" not in py_out
    assert "This should not print" not in zy_out


def test_assert_with_message():
    """Test assertion with custom message"""
    code = """
x = 5
assert x == 10, "x should equal 10"
print("This should not print")
"""
    py_out, zy_out, py_exit, zy_exit = run_code(code)

    # Both should fail
    assert py_exit != 0
    assert zy_exit != 0

    # Both should include custom message
    assert "x should equal 10" in py_out
    assert "x should equal 10" in zy_out


def test_assert_comparison_operators():
    """Test various comparison operators in assertions"""
    code = """
x = 10
assert x == 10
assert x != 5
assert x > 5
assert x >= 10
assert x < 15
assert x <= 10
print("All comparisons passed")
"""
    py_out, zy_out, py_exit, zy_exit = run_code(code)

    assert py_exit == 0
    assert zy_exit == 0
    assert "All comparisons passed" in py_out
    assert "All comparisons passed" in zy_out


def test_assert_boolean_expression():
    """Test assertion with boolean expressions"""
    code = """
x = 5
y = 10
assert x > 0 and y > 0
assert not (x > 10)
print("Boolean assertions passed")
"""
    py_out, zy_out, py_exit, zy_exit = run_code(code)

    assert py_exit == 0
    assert zy_exit == 0
    assert "Boolean assertions passed" in py_out
    assert "Boolean assertions passed" in zy_out


def test_multiple_assertions():
    """Test multiple assertions in sequence"""
    code = """
x = 1
assert x == 1
x = 2
assert x == 2
x = 3
assert x == 3
print("All sequential assertions passed")
"""
    py_out, zy_out, py_exit, zy_exit = run_code(code)

    assert py_exit == 0
    assert zy_exit == 0
    assert "All sequential assertions passed" in py_out
    assert "All sequential assertions passed" in zy_out
