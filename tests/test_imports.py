"""Test import/module system"""
import pytest
import subprocess
import tempfile
from pathlib import Path


def run_example(example_name: str) -> str:
    """Compile and run an example, return stdout"""
    example_file = Path("examples") / f"{example_name}.py"

    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        output_path = tmp.name

    try:
        # Compile
        result = subprocess.run(
            ["uv", "run", "python", "-m", "core.compiler", str(example_file), output_path],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            pytest.fail(f"Compilation failed:\n{result.stderr}")

        # Run compiled binary
        result = subprocess.run(
            [output_path],
            capture_output=True,
            text=True
        )

        return result.stderr.strip()  # Zig prints to stderr
    finally:
        Path(output_path).unlink(missing_ok=True)


def run_python_example(example_name: str) -> str:
    """Run Python version of example, return stdout"""
    example_file = Path("examples") / f"{example_name}.py"

    result = subprocess.run(
        ["python", str(example_file)],
        capture_output=True,
        text=True
    )

    return result.stdout.strip()


def test_import_basic():
    """Test basic module import and function call"""
    zyth_output = run_example("import_mymath")
    py_output = run_python_example("import_mymath")

    assert zyth_output == py_output
    assert zyth_output == "8"


def test_import_multiple_calls():
    """Test multiple function calls from same module"""
    zyth_output = run_example("import_multiple")
    py_output = run_python_example("import_multiple")

    assert zyth_output == py_output
    assert "15" in zyth_output
    assert "12" in zyth_output
    assert "27" in zyth_output


def test_import_nested():
    """Test nested module function calls"""
    zyth_output = run_example("import_nested")
    py_output = run_python_example("import_nested")

    assert zyth_output == py_output
    assert zyth_output == "20"


def test_import_multi_module():
    """Test importing multiple modules"""
    zyth_output = run_example("import_multi_module")
    py_output = run_python_example("import_multi_module")

    assert zyth_output == py_output
    assert "5" in zyth_output
    assert "HiHiHiHiHi" in zyth_output
