"""
zyth.ai - ML/AI utilities module

Machine learning and AI utilities for Zyth.
Actual implementation in src/ai.zig
"""

__version__ = "0.1.0"


class Tensor:
    """Multi-dimensional array (NumPy-compatible)"""

    def __init__(self, data: list, shape: tuple) -> None:
        """Create tensor"""
        ...

    def reshape(self, shape: tuple) -> "Tensor":
        """Reshape tensor"""
        ...
