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


def test_import_statement():
    """Test basic import statement (stub)"""
    zyth_output = run_example("import_simple")
    assert zyth_output == "Test passed"


def test_import_from_statement():
    """Test from...import statement doesn't crash"""
    # Create inline test for from...import
    import os
    with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as f:
        f.write("""
from pytest import fixture

x = 20
print(x)
""")
        test_file = f.name

    try:
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            output_path = tmp.name

        # Compile
        result = subprocess.run(
            ["uv", "run", "python", "-m", "core.compiler", test_file, output_path],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            pytest.fail(f"Compilation failed:\n{result.stderr}")

        # Run
        result = subprocess.run(
            [output_path],
            capture_output=True,
            text=True
        )

        assert result.stderr.strip() == "20"
        Path(output_path).unlink(missing_ok=True)
    finally:
        os.unlink(test_file)


def test_pytest_import():
    """Test that pytest import doesn't crash"""
    zyth_output = run_example("import_simple")
    # The example imports pytest and runs test
    assert "Test passed" in zyth_output


def test_pytest_decorator_stub():
    """Test pytest decorator stubs work (don't crash during compilation)"""
    # Create inline test with decorators
    import os
    with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as f:
        f.write("""
import pytest

# Test that decorators don't crash compilation
@pytest.fixture
def dummy_fixture():
    x = 42
    print(x)

dummy_fixture()
""")
        test_file = f.name

    try:
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            output_path = tmp.name

        # Compile
        result = subprocess.run(
            ["uv", "run", "python", "-m", "core.compiler", test_file, output_path],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            pytest.fail(f"Compilation failed:\n{result.stderr}")

        # Run
        result = subprocess.run(
            [output_path],
            capture_output=True,
            text=True
        )

        assert result.stderr.strip() == "42"
        Path(output_path).unlink(missing_ok=True)
    finally:
        os.unlink(test_file)
