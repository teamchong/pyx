"""Test pop() in arithmetic expressions"""
import subprocess
import tempfile
from pathlib import Path

def test_pop_in_addition():
    """Test: total = total + numbers.pop()"""
    code = '''
numbers = [1, 2, 3]
total = 0
total = total + numbers.pop()
print(total)
'''
    
    with tempfile.TemporaryDirectory() as tmpdir:
        # Write test file
        test_file = Path(tmpdir) / "test.py"
        test_file.write_text(code)
        
        # Get Python output
        py_result = subprocess.run(
            ["python", str(test_file)],
            capture_output=True,
            text=True
        )
        
        # Compile with Zyth
        binary = Path(tmpdir) / "test"
        compile_result = subprocess.run(
            ["uv", "run", "python", "-m", "core.compiler", str(test_file), str(binary)],
            capture_output=True,
            text=True
        )
        
        if compile_result.returncode != 0:
            raise AssertionError(f"Compilation failed:\n{compile_result.stderr}")
        
        # Run Zyth binary
        zy_result = subprocess.run(
            [str(binary)],
            capture_output=True,
            text=True
        )
        
        # Compare outputs (ignoring memory leak warnings)
        py_out = py_result.stdout.strip()
        zy_out = zy_result.stderr.strip().split('\n')[0] if zy_result.stderr else ""
        
        assert py_out == zy_out, f"Output mismatch:\nPython: {py_out}\nZyth: {zy_out}"


def test_getitem_in_multiplication():
    """Test: total = total * numbers[i]"""
    code = '''
numbers = [2, 3, 4]
total = 1
for i in range(3):
    total = total * numbers[i]
print(total)
'''
    
    with tempfile.TemporaryDirectory() as tmpdir:
        # Write test file
        test_file = Path(tmpdir) / "test.py"
        test_file.write_text(code)
        
        # Get Python output
        py_result = subprocess.run(
            ["python", str(test_file)],
            capture_output=True,
            text=True
        )
        
        # Compile with Zyth
        binary = Path(tmpdir) / "test"
        compile_result = subprocess.run(
            ["uv", "run", "python", "-m", "core.compiler", str(test_file), str(binary)],
            capture_output=True,
            text=True
        )
        
        if compile_result.returncode != 0:
            raise AssertionError(f"Compilation failed:\n{compile_result.stderr}")
        
        # Run Zyth binary
        zy_result = subprocess.run(
            [str(binary)],
            capture_output=True,
            text=True
        )
        
        # Compare outputs
        py_out = py_result.stdout.strip()
        zy_out = zy_result.stderr.strip().split('\n')[0] if zy_result.stderr else ""
        
        assert py_out == zy_out, f"Output mismatch:\nPython: {py_out}\nZyth: {zy_out}"
