"""
Zyth Compiler - Compiles generated Zig code to binary
"""
import subprocess
import tempfile
from pathlib import Path
from typing import Optional
import shutil


class CompilationError(Exception):
    """Raised when Zig compilation fails"""
    pass


def compile_zig(zig_code: str, output_path: Optional[str] = None) -> str:
    """
    Compile Zig code to executable binary

    Args:
        zig_code: Zig source code
        output_path: Optional output path for binary

    Returns:
        Path to compiled binary

    Raises:
        CompilationError: If compilation fails
    """
    # Inline runtime if needed
    if '@import("runtime")' in zig_code:
        # Find runtime.zig - try multiple locations
        possible_paths = [
            Path(__file__).parent.parent.parent / "runtime" / "src" / "runtime.zig",  # Development
            Path.cwd() / "packages" / "runtime" / "src" / "runtime.zig",  # Monorepo root
        ]

        runtime_source = None
        for path in possible_paths:
            if path.exists():
                runtime_source = path
                break

        if not runtime_source:
            raise CompilationError(
                f"Runtime library not found. Searched:\n" +
                "\n".join(f"  - {p}" for p in possible_paths)
            )

        # Read runtime code and inline it
        runtime_code = runtime_source.read_text()

        # Remove imports from generated code since runtime has them
        zig_code_lines = zig_code.split("\n")
        new_lines = []
        for line in zig_code_lines:
            # Skip import lines - runtime already has them
            if '@import("runtime")' in line or (line.strip().startswith('const std = @import("std")') and new_lines == []):
                continue
            # Remove runtime. prefix since we're inlining
            line = line.replace("runtime.", "")
            new_lines.append(line)

        # Prepend runtime code
        zig_code = runtime_code + "\n\n" + "\n".join(new_lines)

    # Create temporary directory for compilation
    with tempfile.TemporaryDirectory() as tmpdir:
        # Write Zig code to file
        zig_file = Path(tmpdir) / "main.zig"
        zig_file.write_text(zig_code)

        # Determine output path
        if output_path is None:
            output_path = str(Path(tmpdir) / "output")

        # Compile with Zig
        try:
            subprocess.run(
                ["zig", "build-exe", str(zig_file), "-O", "ReleaseFast"],
                cwd=tmpdir,
                capture_output=True,
                text=True,
                check=True
            )

            # Zig places the binary in the same directory as the source
            compiled_binary = Path(tmpdir) / "main"

            if not compiled_binary.exists():
                raise CompilationError("Compilation succeeded but binary not found")

            # Move binary to desired location if specified
            if output_path:
                output_dest = Path(output_path)
                output_dest.parent.mkdir(parents=True, exist_ok=True)

                # Copy instead of move since we're in temp dir
                shutil.copy2(str(compiled_binary), str(output_dest))
                return str(output_dest)

            return str(compiled_binary)

        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else e.stdout
            raise CompilationError(f"Zig compilation failed:\n{error_msg}") from e


if __name__ == "__main__":
    import sys
    from zyth_core.parser import parse_file
    from zyth_core.codegen import generate_code

    if len(sys.argv) < 2:
        print("Usage: python -m zyth_core.compiler <file.py> [output]")
        sys.exit(1)

    filepath = sys.argv[1]
    output_path_arg = sys.argv[2] if len(sys.argv) > 2 else None

    # Parse Python file
    print(f"Parsing {filepath}...")
    parsed = parse_file(filepath)

    # Generate Zig code
    print("Generating Zig code...")
    zig_code = generate_code(parsed)

    # Compile to binary
    print("Compiling...")
    binary_path = compile_zig(zig_code, output_path_arg)

    print(f"✓ Compiled successfully to: {binary_path}")
