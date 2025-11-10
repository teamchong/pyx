"""Tests for class inheritance"""
import subprocess
from pathlib import Path


def test_vehicle_inheritance(tmp_path):
    """Test basic inheritance with Vehicle/Car classes"""
    # Compile Python version
    result_py = subprocess.run(
        ["python", "examples/class_inherit_vehicle.py"],
        capture_output=True,
        text=True
    )

    # Compile Zyth version
    output_path = tmp_path / "vehicle_test"
    subprocess.run(
        ["uv", "run", "python", "-m", "core.compiler",
         "examples/class_inherit_vehicle.py", str(output_path)],
        check=True,
        capture_output=True
    )

    # Run compiled binary
    result_zy = subprocess.run(
        [str(output_path)],
        capture_output=True,
        text=True
    )

    # Compare outputs
    assert result_py.stdout == result_zy.stderr, f"Python: {result_py.stdout}, Zyth: {result_zy.stderr}"


def test_shape_inheritance(tmp_path):
    """Test inheritance with Shape/Rectangle classes"""
    # Compile Python version
    result_py = subprocess.run(
        ["python", "examples/class_inherit_shape.py"],
        capture_output=True,
        text=True
    )

    # Compile Zyth version
    output_path = tmp_path / "shape_test"
    subprocess.run(
        ["uv", "run", "python", "-m", "core.compiler",
         "examples/class_inherit_shape.py", str(output_path)],
        check=True,
        capture_output=True
    )

    # Run compiled binary
    result_zy = subprocess.run(
        [str(output_path)],
        capture_output=True,
        text=True
    )

    # Compare outputs
    assert result_py.stdout == result_zy.stderr, f"Python: {result_py.stdout}, Zyth: {result_zy.stderr}"


def test_simple_inheritance(tmp_path):
    """Test inheritance with Animal/Dog classes and string fields"""
    # Compile Python version
    result_py = subprocess.run(
        ["python", "examples/class_inherit_simple.py"],
        capture_output=True,
        text=True
    )

    # Compile Zyth version
    output_path = tmp_path / "simple_test"
    subprocess.run(
        ["uv", "run", "python", "-m", "core.compiler",
         "examples/class_inherit_simple.py", str(output_path)],
        check=True,
        capture_output=True
    )

    # Run compiled binary
    result_zy = subprocess.run(
        [str(output_path)],
        capture_output=True,
        text=True
    )

    # Compare outputs
    assert result_py.stdout == result_zy.stderr, f"Python: {result_py.stdout}, Zyth: {result_zy.stderr}"
