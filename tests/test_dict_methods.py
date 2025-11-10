"""Test suite for dict methods"""
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


class TestDictMethods:
    """Test all dict methods"""

    @pytest.mark.parametrize("code,desc", [
        ('d = {"a": 1, "b": 2}\nkeys = d.keys()\nprint(len(keys))', "keys() length"),
        ('d = {"a": 1, "b": 2}\nvals = d.values()\nprint(len(vals))', "values() length"),
        ('d = {"a": 1, "b": 2}\nitems = d.items()\nprint(len(items))', "items() length"),
        # items()[0] is not valid Python 3 - dict_items is not subscriptable
        ('d = {"a": 1}\nval = d.get("a", 0)\nprint(val)', "get() found"),
        ('d = {"a": 1}\nval = d.get("b", 0)\nprint(val)', "get() not found"),
        ('d = {"a": 1, "b": 2}\nd2 = d.copy()\nprint(len(d2))', "copy() length"),
        ('d = {"a": 1, "b": 2}\nd.clear()\nprint(len(d))', "clear() basic"),
        ('d1 = {"a": 1}\nd2 = {"b": 2}\nd1.update(d2)\nprint(len(d1))', "update() basic"),
    ])
    def test_dict_method(self, code, desc):
        """Test dict methods match Python behavior"""
        py_out, zy_out = run_code(code)
        assert py_out == zy_out, f"{desc}: Python={py_out!r}, Zyth={zy_out!r}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
