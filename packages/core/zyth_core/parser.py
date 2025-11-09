"""
Zyth Parser - Converts Python source to AST
"""
import ast
from dataclasses import dataclass


@dataclass
class ParsedModule:
    """Represents a parsed Python module"""
    ast_tree: ast.Module
    source: str
    filename: str


def parse_file(filepath: str) -> ParsedModule:
    """
    Parse a Python file and return the AST

    Args:
        filepath: Path to Python file

    Returns:
        ParsedModule containing AST and metadata
    """
    with open(filepath, 'r') as f:
        source = f.read()

    try:
        ast_tree = ast.parse(source, filepath)
        return ParsedModule(
            ast_tree=ast_tree,
            source=source,
            filename=filepath
        )
    except SyntaxError as e:
        raise SyntaxError(f"Failed to parse {filepath}: {e}") from e


def dump_ast(parsed: ParsedModule) -> str:
    """Debug helper to visualize AST"""
    return ast.dump(parsed.ast_tree, indent=2)


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python -m zyth_core.parser <file.py>")
        sys.exit(1)

    filepath = sys.argv[1]
    parsed = parse_file(filepath)
    print(f"✓ Parsed {filepath}")
    print(f"\nAST:\n{dump_ast(parsed)}")
