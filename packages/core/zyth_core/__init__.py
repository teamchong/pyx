"""
Zyth Core Compiler Package

Main components:
- Parser: Python AST → Internal IR
- Type Checker: Type inference engine
- Code Generator: IR → Zig code
- Compiler: Orchestration and Zig compilation
"""

from zyth_core.parser import ParsedModule, parse_file, dump_ast
from zyth_core.codegen import ZigCodeGenerator, generate_code
from zyth_core.compiler import compile_zig, CompilationError

__version__ = "0.1.0"

__all__ = [
    # Parser
    "ParsedModule",
    "parse_file",
    "dump_ast",
    # Code Generator
    "ZigCodeGenerator",
    "generate_code",
    # Compiler
    "compile_zig",
    "CompilationError",
]
