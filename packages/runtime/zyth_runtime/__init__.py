"""
Zyth Runtime Package

Python wrapper for Zig runtime library.
The actual runtime is implemented in Zig (see src/runtime.zig).
"""

__version__ = "0.1.0"

# Path to Zig runtime source
import pathlib
RUNTIME_PATH = pathlib.Path(__file__).parent.parent / "src"
