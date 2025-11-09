"""
Method registry for Python runtime methods.

This module defines metadata for all supported Python methods and provides
a clean interface for code generation.
"""

from dataclasses import dataclass
from enum import Enum
from typing import Optional


class ArgType(Enum):
    """Argument type for method calls"""
    ANY = "any"  # Accept any type (primitive or PyObject)
    PYOBJECT = "pyobject"  # Requires PyObject
    PRIMITIVE = "primitive"  # Requires primitive (int, str literal)


class ReturnType(Enum):
    """Return type from method calls"""
    PYOBJECT = "pyobject"  # Returns !*PyObject (error union, needs try)
    PYOBJECT_DIRECT = "pyobject_direct"  # Returns *PyObject (no error union, no try)
    PRIMITIVE_INT = "int"  # Returns i64
    VOID = "void"  # Returns nothing (like append)


@dataclass
class MethodInfo:
    """Metadata for a Python method"""
    name: str  # Method name (e.g., "upper", "append")
    runtime_type: str  # Runtime type (e.g., "PyString", "PyList")
    runtime_fn: str  # Runtime function name (e.g., "upper", "append")
    needs_allocator: bool  # Whether to pass allocator argument
    return_type: ReturnType  # What the method returns
    arg_types: list[ArgType]  # Expected argument types
    wrap_primitive_args: bool = False  # Wrap primitives in PyInt
    is_statement: bool = False  # True for methods like append() that don't return values

    def generate_call(
        self,
        obj_code: str,
        args: list[tuple[str, bool]],
        allocator: str = "allocator"
    ) -> tuple[str, bool]:
        """
        Generate Zig code for this method call.

        Args:
            obj_code: Code for the object being called on
            args: List of (arg_code, needs_try) tuples
            allocator: Allocator variable name

        Returns:
            (generated_code, needs_try) tuple
        """
        # Build argument list
        # For string methods, allocator comes first: (allocator, obj)
        # For list methods, obj comes first: (obj, [allocator])
        arg_list = []

        if self.runtime_type == "PyString" and self.needs_allocator:
            # String methods: allocator, obj, ...args
            arg_list.append(allocator)
            arg_list.append(obj_code)
        else:
            # List/Dict methods: obj, [allocator], ...args
            arg_list.append(obj_code)
            if self.needs_allocator:
                arg_list.append(allocator)

        # Add method arguments
        for i, (arg_code, arg_try) in enumerate(args):
            if i < len(self.arg_types):
                arg_type = self.arg_types[i]

                # If we need to wrap primitives and this is a primitive
                if self.wrap_primitive_args and not arg_try:
                    # This will be handled specially - return a marker
                    arg_list.append(f"__WRAP_PRIMITIVE__{arg_code}")
                elif arg_try:
                    # Argument needs try - wrap it
                    arg_list.append(f"try {arg_code}")
                else:
                    arg_list.append(arg_code)
            else:
                # Handle generic arguments
                if arg_try:
                    arg_list.append(f"try {arg_code}")
                else:
                    arg_list.append(arg_code)

        args_str = ", ".join(arg_list)
        call_code = f"runtime.{self.runtime_type}.{self.runtime_fn}({args_str})"

        # Determine if this needs try
        # Only PYOBJECT (error unions) need try, not PYOBJECT_DIRECT
        needs_try = self.return_type == ReturnType.PYOBJECT

        return (call_code, needs_try)


# Method Registry
METHOD_REGISTRY: dict[str, MethodInfo] = {
    # String methods
    "upper": MethodInfo(
        name="upper",
        runtime_type="PyString",
        runtime_fn="upper",
        needs_allocator=True,
        return_type=ReturnType.PYOBJECT,
        arg_types=[],
    ),
    "lower": MethodInfo(
        name="lower",
        runtime_type="PyString",
        runtime_fn="lower",
        needs_allocator=True,
        return_type=ReturnType.PYOBJECT,
        arg_types=[],
    ),
    "split": MethodInfo(
        name="split",
        runtime_type="PyString",
        runtime_fn="split",
        needs_allocator=True,
        return_type=ReturnType.PYOBJECT,
        arg_types=[ArgType.PYOBJECT],  # Separator string
    ),
    "strip": MethodInfo(
        name="strip",
        runtime_type="PyString",
        runtime_fn="strip",
        needs_allocator=True,
        return_type=ReturnType.PYOBJECT,
        arg_types=[],
    ),
    "replace": MethodInfo(
        name="replace",
        runtime_type="PyString",
        runtime_fn="replace",
        needs_allocator=True,
        return_type=ReturnType.PYOBJECT,
        arg_types=[ArgType.PYOBJECT, ArgType.PYOBJECT],  # old, new
    ),

    # List methods
    "append": MethodInfo(
        name="append",
        runtime_type="PyList",
        runtime_fn="append",
        needs_allocator=False,
        return_type=ReturnType.VOID,
        arg_types=[ArgType.ANY],
        wrap_primitive_args=True,
        is_statement=True,
    ),
    "pop": MethodInfo(
        name="pop",
        runtime_type="PyList",
        runtime_fn="pop",
        needs_allocator=True,
        return_type=ReturnType.PYOBJECT_DIRECT,  # Returns *PyObject, no error union
        arg_types=[],
    ),
}


def get_method_info(method_name: str) -> Optional[MethodInfo]:
    """Get method metadata by name"""
    return METHOD_REGISTRY.get(method_name)


def register_method(method_info: MethodInfo) -> None:
    """Register a new method"""
    METHOD_REGISTRY[method_info.name] = method_info
