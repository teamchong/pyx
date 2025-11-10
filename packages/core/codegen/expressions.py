"""
Expression visitor - extracted from generator.py
533 lines extracted to reduce generator.py size
"""
from __future__ import annotations

import ast
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from core.parser import ParsedModule
    from core.codegen.generator import ClassInfo


class ExpressionVisitor:
    """Handles visit_expr and expression evaluation"""

    # Provided by ZigCodeGenerator
    var_types: dict[str, str]
    declared_vars: set
    imported_modules: dict[str, ParsedModule]
    class_definitions: dict[str, ClassInfo]
    function_signatures: dict[str, dict]
    module_functions: dict[str, dict[str, dict]]

    # Methods from other mixins
    def visit_compare_op(self, op: ast.AST) -> str: ...
    def visit_bin_op(self, op: ast.AST) -> str: ...

    def visit_expr(self, node: ast.AST) -> tuple[str, bool]:
        """Visit an expression node and return (code, needs_try) tuple"""
        if isinstance(node, ast.Name):
            return (node.id, False)

        elif isinstance(node, ast.Constant):
            if isinstance(node.value, str):
                return (f'runtime.PyString.create(allocator, "{node.value}")', True)
            elif isinstance(node.value, bool):
                return ("true" if node.value else "false", False)
            else:
                return (str(node.value), False)

        elif isinstance(node, ast.Compare):
            left_code, left_try = self.visit_expr(node.left)
            right_code, right_try = self.visit_expr(node.comparators[0])

            if isinstance(node.ops[0], ast.In):
                return (f"__in_operator__{left_code}__{left_try}__{right_code}", False)

            left_expr = left_code
            if isinstance(node.left, ast.Name) and self.var_types.get(node.left.id) == "pyint":
                left_expr = f"runtime.PyInt.getValue({left_code})"

            right_expr = right_code
            if isinstance(node.comparators[0], ast.Name) and self.var_types.get(node.comparators[0].id) == "pyint":
                right_expr = f"runtime.PyInt.getValue({right_code})"

            op = self.visit_compare_op(node.ops[0])
            return (f"{left_expr} {op} {right_expr}", False)

        elif isinstance(node, ast.BinOp):
            left_code, left_try = self.visit_expr(node.left)
            right_code, right_try = self.visit_expr(node.right)

            left_is_string = False
            right_is_string = False
            left_is_pyint = False
            right_is_pyint = False
            if isinstance(node.left, ast.Name):
                left_is_string = self.var_types.get(node.left.id) == "string"
                left_is_pyint = self.var_types.get(node.left.id) == "pyint"
            if isinstance(node.right, ast.Name):
                right_is_string = self.var_types.get(node.right.id) == "string"
                right_is_pyint = self.var_types.get(node.right.id) == "pyint"

            if isinstance(node.op, ast.Add) and (left_try or right_try or left_is_string or right_is_string):
                left_expr = f"try {left_code}" if left_try else left_code
                right_expr = f"try {right_code}" if right_try else right_code
                return (f"runtime.PyString.concat(allocator, {left_expr}, {right_expr})", True)

            # Unwrap PyInt values for arithmetic operations
            if left_is_pyint:
                left_code = f"runtime.PyInt.getValue({left_code})"
            if right_is_pyint:
                right_code = f"runtime.PyInt.getValue({right_code})"

            op = self.visit_bin_op(node.op)
            needs_try = left_try or right_try
            return (f"{left_code} {op} {right_code}", needs_try)

        elif isinstance(node, ast.List):
            if not node.elts:
                return ("runtime.PyList.create(allocator)", True)

            element_codes = []
            for elt in node.elts:
                elt_code, elt_try = self.visit_expr(elt)
                element_codes.append(elt_code)

            elements_str = ", ".join(f".{{ .int = {code} }}" for code in element_codes)
            return (f"runtime.PyList.fromSlice(allocator, &[_]runtime.PyObject.Value{{ {elements_str} }})", True)

        elif isinstance(node, ast.Tuple):
            if not node.elts:
                return ("runtime.PyTuple.create(allocator, 0)", True)

            element_codes = []
            for elt in node.elts:
                elt_code, elt_try = self.visit_expr(elt)
                element_codes.append(elt_code)

            elements_str = ", ".join(f".{{ .int = {code} }}" for code in element_codes)
            return (f"runtime.PyTuple.fromSlice(allocator, &[_]runtime.PyObject.Value{{ {elements_str} }})", True)

        elif isinstance(node, ast.Dict):
            if not node.keys:
                return ("runtime.PyDict.create(allocator)", True)

            items = []
            for key_node, val_node in zip(node.keys, node.values):
                if key_node is None:
                    continue
                key_code, key_try = self.visit_expr(key_node)
                val_code, val_try = self.visit_expr(val_node)
                items.append((key_code, val_code, key_try, val_try))

            return ("__dict_literal__" + "|||".join(f"{k};;{v};;{kt};;{vt}" for k, v, kt, vt in items), True)

        elif isinstance(node, ast.ListComp):
            return self._visit_list_comp(node)

        elif isinstance(node, ast.Subscript):
            obj_code, obj_try = self.visit_expr(node.value)

            if isinstance(node.slice, ast.Slice):
                start_code = "null"
                end_code = "null"
                step_code = "null"

                if node.slice.lower:
                    start_val, start_try = self.visit_expr(node.slice.lower)
                    start_code = start_val

                if node.slice.upper:
                    end_val, end_try = self.visit_expr(node.slice.upper)
                    end_code = end_val

                if node.slice.step:
                    step_val, step_try = self.visit_expr(node.slice.step)
                    step_code = step_val

                # Determine object type for slice method
                obj_type = None
                if isinstance(node.value, ast.Name):
                    obj_type = self.var_types.get(node.value.id)

                if obj_type == "list":
                    return (f"runtime.PyList.slice({obj_code}, allocator, {start_code}, {end_code}, {step_code})", True)
                elif obj_type == "string":
                    return (f"runtime.PyString.slice({obj_code}, allocator, {start_code}, {end_code}, {step_code})", True)
                else:
                    # Default to string slice for unknown types
                    return (f"runtime.PyString.slice({obj_code}, allocator, {start_code}, {end_code}, {step_code})", True)
            elif isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, str):
                # Dict access with string literal key - returns PyObject
                key_str = node.slice.value
                return (f'runtime.PyDict.get({obj_code}, "{key_str}").?', True)
            else:
                index_code, index_try = self.visit_expr(node.slice)

                if isinstance(node.slice, ast.Name) and self.var_types.get(node.slice.id) == "pyint":
                    index_code = f"runtime.PyInt.getValue({index_code})"

                obj_type = None
                if isinstance(node.value, ast.Name):
                    obj_type = self.var_types.get(node.value.id)

                # Cast i64 to usize for list/tuple indexing
                index_type = None
                if isinstance(node.slice, ast.Name):
                    index_type = self.var_types.get(node.slice.id)

                if obj_type == "list":
                    # Always cast to usize for list indexing if it's a variable
                    if isinstance(node.slice, ast.Name):
                        index_code = f"@intCast({index_code})"
                    return (f"runtime.PyList.getItem({obj_code}, {index_code})", True)
                elif obj_type == "tuple":
                    # Always cast to usize for tuple indexing if it's a variable
                    if isinstance(node.slice, ast.Name):
                        index_code = f"@intCast({index_code})"
                    return (f"runtime.PyTuple.getItem({obj_code}, {index_code})", True)
                elif obj_type == "string":
                    return (f"runtime.PyString.getItem(allocator, {obj_code}, {index_code})", True)
                elif obj_type == "dict":
                    return (f'runtime.PyDict.get({obj_code}, "{index_code}").?', False)
                else:
                    return (f"{obj_code}[{index_code}]", obj_try or index_try)

        elif isinstance(node, ast.Attribute):
            obj_code, obj_try = self.visit_expr(node.value)

            if isinstance(node.value, ast.Name) and self.imported_modules and node.value.id in self.imported_modules:
                return (f"__module_call__{node.value.id}__{node.attr}", False)

            return (f"{obj_code}.{node.attr}", obj_try)

        elif isinstance(node, ast.Call):
            return self._visit_call(node)

        elif isinstance(node, ast.BoolOp):
            if isinstance(node.op, ast.And):
                parts = []
                for value in node.values:
                    code, needs_try = self.visit_expr(value)
                    parts.append(code)
                return (" and ".join(parts), False)

            elif isinstance(node.op, ast.Or):
                parts = []
                for value in node.values:
                    code, needs_try = self.visit_expr(value)
                    parts.append(code)
                return (" or ".join(parts), False)

        elif isinstance(node, ast.UnaryOp):
            operand_code, operand_try = self.visit_expr(node.operand)

            if isinstance(node.op, ast.USub):
                return (f"-{operand_code}", operand_try)
            elif isinstance(node.op, ast.UAdd):
                return (f"+{operand_code}", operand_try)
            elif isinstance(node.op, ast.Not):
                return (f"!({operand_code})", operand_try)
            else:
                raise NotImplementedError(f"Unary operator not implemented: {node.op.__class__.__name__}")

        raise NotImplementedError(f"Expression not implemented: {node.__class__.__name__}")

    def _visit_list_comp(self, node: ast.ListComp) -> tuple[str, bool]:
        """Handle list comprehension"""
        target = node.generators[0].target
        iter_node = node.generators[0].iter
        elt_node = node.elt

        target_name = target.id if isinstance(target, ast.Name) else "item"
        iter_code, iter_try = self.visit_expr(iter_node)
        elt_code, elt_try = self.visit_expr(elt_node)

        filter_code = ""
        if node.generators[0].ifs:
            filter_expr = node.generators[0].ifs[0]
            filter_code, filter_try = self.visit_expr(filter_expr)

        return (f"__list_comp__{target_name}__{iter_code}__{elt_code}__{filter_code}", True)

    def _visit_call(self, node: ast.Call) -> tuple[str, bool]:
        """Handle function calls"""
        from core.method_registry import get_method_info, ReturnType

        if isinstance(node.func, ast.Name):
            func_name = node.func.id

            if func_name == "print":
                if not node.args:
                    return ('std.debug.print("\\n", .{})', False)

                arg_code, arg_try = self.visit_expr(node.args[0])
                arg_type = None
                if isinstance(node.args[0], ast.Name):
                    arg_type = self.var_types.get(node.args[0].id)

                if arg_type == "list" or arg_type == "tuple":
                    return (f'runtime.printList({arg_code}); std.debug.print("\\n", .{{}})', False)
                elif arg_type == "dict":
                    return (f'runtime.printDict({arg_code}); std.debug.print("\\n", .{{}})', False)
                elif arg_type == "string":
                    return (f'std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({arg_code})}})', False)
                elif arg_type == "pyint":
                    return (f'std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({arg_code})}})', False)
                elif arg_try:
                    # For subscripts and other expressions that need try
                    # Detect subscripts from lists - they return pyint
                    if isinstance(node.args[0], ast.Subscript):
                        obj_type = None
                        if isinstance(node.args[0].value, ast.Name):
                            obj_type = self.var_types.get(node.args[0].value.id)
                        if obj_type == "list" or obj_type == "tuple":
                            return (f'std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue(try {arg_code})}})', False)
                        elif obj_type == "string":
                            return (f'std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue(try {arg_code})}})', False)
                        elif obj_type == "dict":
                            # Dict values need runtime type checking
                            return (f"__print_pyobject__{arg_code}", False)
                    # Default for string-like expressions (method calls, etc)
                    return (f'std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue(try {arg_code})}})', False)
                else:
                    return (f'std.debug.print("{{}}\\n", .{{{arg_code}}})', False)

            elif func_name == "len":
                arg_code, arg_try = self.visit_expr(node.args[0])
                arg_type = None
                if isinstance(node.args[0], ast.Name):
                    arg_type = self.var_types.get(node.args[0].id)

                if arg_type == "list":
                    return (f"runtime.PyList.len({arg_code})", False)
                elif arg_type == "tuple":
                    return (f"runtime.PyTuple.len({arg_code})", False)
                elif arg_type == "dict":
                    return (f"runtime.PyDict.len({arg_code})", False)
                elif arg_type == "string" or arg_try:
                    return (f"runtime.PyString.len({arg_code})", False)
                else:
                    return (f"{arg_code}.len", False)

            elif func_name == "min":
                args = [self.visit_expr(arg)[0] for arg in node.args]
                return (f"@min({', '.join(args)})", False)

            elif func_name == "max":
                args = [self.visit_expr(arg)[0] for arg in node.args]
                return (f"@max({', '.join(args)})", False)

            elif func_name == "sum":
                arg_code, arg_try = self.visit_expr(node.args[0])
                arg_type = None
                if isinstance(node.args[0], ast.Name):
                    arg_type = self.var_types.get(node.args[0].id)

                if arg_type == "list":
                    return (f"runtime.PyList.sum({arg_code})", False)
                else:
                    return (f"sum({arg_code})", False)

            elif func_name == "range":
                if len(node.args) == 1:
                    end_code, _ = self.visit_expr(node.args[0])
                    return (f"runtime.range(allocator, 0, {end_code})", True)
                elif len(node.args) == 2:
                    start_code, _ = self.visit_expr(node.args[0])
                    end_code, _ = self.visit_expr(node.args[1])
                    return (f"runtime.range(allocator, {start_code}, {end_code})", True)
                else:
                    raise NotImplementedError("range() with step not yet supported")

            elif func_name == "enumerate":
                arg_code, _ = self.visit_expr(node.args[0])
                return (f"runtime.enumerate(allocator, {arg_code})", True)

            elif func_name == "zip":
                arg_codes = [self.visit_expr(arg)[0] for arg in node.args]
                return (f"runtime.zip(allocator, {', '.join(arg_codes)})", True)

            # Check if it's a class instantiation
            elif func_name in self.class_definitions:
                args = []
                for arg in node.args:
                    arg_code, arg_try = self.visit_expr(arg)
                    # Add "try" if argument returns an error union
                    if arg_try:
                        arg_code = f"try {arg_code}"
                    args.append(arg_code)
                # Class instantiation requires allocator and uses .init method
                return (f"{func_name}.init(allocator, {', '.join(args)})", True)

            else:
                # User-defined function call - check if needs allocator
                args = []
                needs_try = False

                # Check if this is a user-defined function that needs allocator
                if func_name in self.function_signatures:
                    sig = self.function_signatures[func_name]
                    if sig["needs_allocator"]:
                        args.append("allocator")
                    needs_try = sig.get("returns_pyobject", False)

                for arg in node.args:
                    arg_code, arg_try = self.visit_expr(arg)
                    if arg_try:
                        arg_code = f"try {arg_code}"
                    args.append(arg_code)
                return (f"{func_name}({', '.join(args)})", needs_try)

        elif isinstance(node.func, ast.Attribute):
            obj_code, obj_try = self.visit_expr(node.func.value)
            method_name = node.func.attr

            obj_type = None
            if isinstance(node.func.value, ast.Name):
                obj_type = self.var_types.get(node.func.value.id)

            # Check if it's a class method (user-defined class)
            if obj_type and obj_type in self.class_definitions:
                class_info = self.class_definitions[obj_type]
                if method_name in class_info.methods:
                    method_sig = class_info.methods[method_name]
                    args = []
                    # Add allocator if method needs it
                    if method_sig.get("needs_allocator", False):
                        args.append("allocator")
                    # Add method arguments
                    for arg in node.args:
                        arg_code, arg_try = self.visit_expr(arg)
                        if arg_try:
                            args.append(f"try {arg_code}")
                        else:
                            args.append(arg_code)
                    # Check if return type is a PyObject (needs try)
                    return_type = method_sig.get("return_type", "void")
                    needs_try = return_type == "*runtime.PyObject" or method_sig.get("needs_allocator", False)
                    return (f"{obj_code}.{method_name}({', '.join(args)})", needs_try)

            method_info = get_method_info(method_name, obj_type)

            if method_info:
                args = []
                args.append(obj_code)
                if method_info.needs_allocator:
                    args.append("allocator")

                # Track method arguments separately for VOID methods (statement methods)
                method_args = []
                for arg_node in node.args:
                    arg_code, arg_try = self.visit_expr(arg_node)
                    method_args.append((arg_code, arg_try))
                    if arg_try:
                        args.append(f"try {arg_code}")
                    else:
                        args.append(arg_code)

                runtime_call = f"runtime.{method_info.runtime_type}.{method_info.runtime_fn}({', '.join(args)})"

                if method_info.return_type == ReturnType.VOID:
                    # Format: __list_append__obj__arg|||try;;;arg2|||try2
                    # Convert PyList -> list, PyDict -> dict
                    type_name = method_info.runtime_type.replace("Py", "").lower()
                    args_marker = ";;;".join(f"{arg_code}|||{arg_try}" for arg_code, arg_try in method_args)
                    return (f"__{type_name}_{method_info.runtime_fn}__{obj_code}__{args_marker}", False)

                needs_try = method_info.return_type == ReturnType.PYOBJECT
                return (runtime_call, needs_try)

            # Handle imported module function calls and other attribute calls
            args = []
            needs_try = obj_try

            # Check if this is a module function call that needs allocator
            if isinstance(node.func.value, ast.Name):
                module_name = node.func.value.id
                if module_name in self.module_functions:
                    if method_name in self.module_functions[module_name]:
                        sig = self.module_functions[module_name][method_name]
                        if sig["needs_allocator"]:
                            args.append("allocator")
                        needs_try = sig.get("returns_pyobject", False)

            for arg in node.args:
                arg_code, arg_try = self.visit_expr(arg)
                if arg_try:
                    args.append(f"try {arg_code}")
                else:
                    args.append(arg_code)

            return (f"{obj_code}.{method_name}({', '.join(args)})", needs_try)

        else:
            raise NotImplementedError(f"Call expression not implemented: {node.func.__class__.__name__}")
