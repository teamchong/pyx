#!/usr/bin/env python3
"""
Zyth CLI - Command-line interface for Zyth compiler
"""
import sys
import argparse
from pathlib import Path
import subprocess

from zyth_core.parser import parse_file
from zyth_core.codegen import generate_code
from zyth_core.compiler import compile_zig


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Zyth: Python to Zig compiler",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  zyth run app.py              # Compile and run
  zyth build app.py -o binary  # Compile to binary
  zyth --show-zig app.py       # Show generated Zig code
        """
    )

    parser.add_argument("file", help="Python file to compile")
    parser.add_argument(
        "-o", "--output",
        help="Output binary path (default: ./output)",
        default="./output"
    )
    parser.add_argument(
        "--show-zig",
        action="store_true",
        help="Print generated Zig code"
    )
    parser.add_argument(
        "--run",
        action="store_true",
        help="Run the compiled binary immediately"
    )

    args = parser.parse_args()

    try:
        # Parse Python file
        print(f"[1/3] Parsing {args.file}...")
        parsed = parse_file(args.file)

        # Generate Zig code
        print("[2/3] Generating Zig code...")
        zig_code = generate_code(parsed)

        if args.show_zig:
            print("\n" + "=" * 60)
            print("Generated Zig code:")
            print("=" * 60)
            print(zig_code)
            print("=" * 60 + "\n")

        # Compile to binary
        print("[3/3] Compiling to binary...")
        binary_path = compile_zig(zig_code, args.output)

        print(f"\n✓ Compilation successful!")
        print(f"  Binary: {binary_path}")

        # Run if requested
        if args.run:
            print(f"\nRunning {binary_path}...\n")
            print("-" * 60)
            # Resolve to absolute path to avoid subprocess issues
            binary_abs = str(Path(binary_path).resolve())
            result = subprocess.run([binary_abs])
            print("-" * 60)
            sys.exit(result.returncode)

    except Exception as e:
        print(f"\n✗ Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
