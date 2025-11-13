#!/usr/bin/env python3
"""
Zyth CLI - Command-line interface for Zyth compiler
"""
import sys
import os
import argparse
from pathlib import Path
import subprocess
from typing import List

from core.parser import parse_file
from core.codegen import generate_code
from core.compiler import compile_zig


def needs_recompile(source_path: Path, binary_path: Path) -> bool:
    """Check if binary needs recompilation (source newer than binary)"""
    if not binary_path.exists():
        return True
    return source_path.stat().st_mtime > binary_path.stat().st_mtime


def get_binary_path(source_path: Path, output_dir: Path | None = None) -> Path:
    """Get output binary path for a source file"""
    if output_dir:
        return output_dir / source_path.stem
    return Path("./bin") / source_path.stem


def collect_python_files(path: Path, recursive: bool = True) -> List[Path]:
    """Collect .py files from path"""
    if path.is_file():
        return [path] if path.suffix == ".py" else []

    if recursive:
        return list(path.rglob("*.py"))
    else:
        return list(path.glob("*.py"))


def compile_file(source_path: Path, binary_path: Path, show_zig: bool = False, force: bool = False) -> bool:
    """Compile a single Python file to binary. Returns True if compiled, False if skipped."""
    source_path = Path(source_path).resolve()

    # Check if recompilation needed
    if not force and not needs_recompile(source_path, binary_path):
        return False

    try:
        # Parse Python file
        parsed = parse_file(str(source_path))

        # Generate Zig code
        zig_code = generate_code(parsed)

        if show_zig:
            print("\n" + "=" * 60)
            print(f"Generated Zig code for {source_path.name}:")
            print("=" * 60)
            print(zig_code)
            print("=" * 60 + "\n")

        # Ensure output directory exists
        binary_path.parent.mkdir(parents=True, exist_ok=True)

        # Compile to binary
        compile_zig(zig_code, str(binary_path))

        return True

    except Exception as e:
        print(f"\n✗ Error compiling {source_path}: {e}", file=sys.stderr)
        return False


def cmd_run(args):
    """Run a Python file (compile if needed, then execute)"""
    source_path = Path(args.file)
    if not source_path.exists():
        print(f"✗ File not found: {args.file}", file=sys.stderr)
        sys.exit(1)

    binary_path = get_binary_path(source_path, args.output)

    # Compile if needed (silent if cached)
    if needs_recompile(source_path, binary_path):
        print(f"⚙ Compiling {source_path.name}...")
        if not compile_file(source_path, binary_path, args.show_zig, force=True):
            sys.exit(1)
        print(f"✓ Compiled to {binary_path}\n")

    # Run the binary
    result = subprocess.run([str(binary_path.resolve())])
    sys.exit(result.returncode)


def cmd_build(args):
    """Build Python files without running"""
    path = Path(args.path) if args.path else Path(".")

    # Determine recursive mode
    # Default: recursive for all paths
    # Exception: '.' means current dir only (non-recursive)
    recursive = True
    if args.path == '.':
        recursive = False

    # Normalize path (remove trailing slash if present)
    if args.path and args.path.endswith('/'):
        path = Path(args.path.rstrip('/'))

    # Collect files
    files = collect_python_files(path, recursive)

    if not files:
        print(f"✗ No Python files found in {path}", file=sys.stderr)
        sys.exit(1)

    # Build all files
    print(f"Building {len(files)} file(s)...\n")
    compiled = 0
    skipped = 0
    failed = 0

    for source_path in files:
        binary_path = get_binary_path(source_path, args.output)

        # Always compile in build mode (force=True)
        print(f"  {source_path.name:30} → {binary_path}")
        if compile_file(source_path, binary_path, args.show_zig, force=True):
            compiled += 1
        else:
            failed += 1

    print(f"\n✓ Build complete: {compiled} compiled, {failed} failed")
    if failed > 0:
        sys.exit(1)


def cmd_test(args):
    """Run pytest test suite"""
    import subprocess

    # Run pytest with proper arguments
    cmd = ["pytest"]

    # Add path filter if specified
    if hasattr(args, 'filter') and args.filter:
        # If filter looks like a path, use it as path, otherwise as -k keyword
        if '/' in args.filter or args.filter.endswith('.py'):
            cmd.append(args.filter)
        else:
            cmd.extend(['-k', args.filter])

    # Add verbosity (default to verbose)
    cmd.append('-v')

    # Run tests
    result = subprocess.run(cmd)
    sys.exit(result.returncode)


def main() -> None:
    # Check if first argument is a subcommand
    if len(sys.argv) > 1 and sys.argv[1] == 'test':
        # Parse as test subcommand
        parser = argparse.ArgumentParser(
            description="Zyth: Run test suite",
            prog="zyth test"
        )
        parser.add_argument(
            'filter',
            nargs='?',
            help='Filter tests (file path or keyword)'
        )

        # Remove 'test' from argv before parsing
        sys.argv.pop(1)
        args = parser.parse_args()
        cmd_test(args)
    elif len(sys.argv) > 1 and sys.argv[1] == 'build':
        # Parse as build subcommand
        parser = argparse.ArgumentParser(
            description="Zyth: Build Python files to binaries",
            prog="zyth build"
        )
        parser.add_argument(
            'path',
            nargs='?',
            help='File or directory to build (default: all files recursively)'
        )
        parser.add_argument(
            '-o', '--output',
            type=Path,
            help='Output directory (default: ./bin)',
            default=Path('./bin')
        )
        parser.add_argument(
            '--show-zig',
            action='store_true',
            help='Print generated Zig code'
        )

        # Remove 'build' from argv before parsing
        sys.argv.pop(1)
        args = parser.parse_args()
        cmd_build(args)
    else:
        # Parse as run command (default)
        parser = argparse.ArgumentParser(
            description="Zyth: Python to Zig AOT compiler",
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog="""
Examples:
  zyth script.py              # Smart run (compile if needed, then execute)
  zyth build                  # Build all .py files recursively → ./bin/
  zyth build .                # Build current dir only (non-recursive) → ./bin/
  zyth build examples/        # Build examples/ recursively → ./bin/
  zyth build script.py        # Build single file → ./bin/script
  zyth test                   # Run all tests
  zyth test fibonacci         # Run tests matching 'fibonacci'
  zyth test tests/test_slicing.py  # Run specific test file
  zyth script.py --show-zig   # Show generated Zig code
            """
        )
        parser.add_argument(
            'file',
            help='Python file to compile and run'
        )
        parser.add_argument(
            '-o', '--output',
            type=Path,
            help='Output directory (default: ./bin)',
        )
        parser.add_argument(
            '--show-zig',
            action='store_true',
            help='Print generated Zig code'
        )

        args = parser.parse_args()
        cmd_run(args)


if __name__ == "__main__":
    main()
