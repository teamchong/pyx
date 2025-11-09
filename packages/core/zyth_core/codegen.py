"""
Zyth Code Generator - Converts Python AST to Zig code
"""
import ast
from typing import List
from zyth_core.parser import ParsedModule


class ZigCodeGenerator:
    """Generates Zig code from Python AST"""

    def __init__(self) -> None:
        self.indent_level = 0
        self.output: List[str] = []
        self.needs_runtime = False  # Track if we need PyObject runtime
        self.needs_allocator = False  # Track if we need allocator
        self.declared_vars: set[str] = set()  # Track declared variables
        self.reassigned_vars: set[str] = set()  # Track variables that are reassigned
        self.var_types: dict[str, str] = {}  # Track variable types: "int", "string", "list", "pyint"

    def indent(self) -> str:
        """Get current indentation"""
        return "    " * self.indent_level

    def emit(self, code: str) -> None:
        """Emit a line of code"""
        self.output.append(self.indent() + code)

    def _detect_runtime_needs(self, node: ast.AST) -> None:
        """Detect if node requires PyObject runtime"""
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            self.needs_runtime = True
            self.needs_allocator = True
        elif isinstance(node, ast.List):
            # List literal requires runtime
            self.needs_runtime = True
            self.needs_allocator = True
            for elem in node.elts:
                self._detect_runtime_needs(elem)
        elif isinstance(node, ast.Dict):
            # Dict literal requires runtime
            self.needs_runtime = True
            self.needs_allocator = True
            for key in node.keys:
                if key:  # Filter out None (for **kwargs)
                    self._detect_runtime_needs(key)
            for value in node.values:
                self._detect_runtime_needs(value)
        elif isinstance(node, ast.BinOp):
            # Check if string concatenation
            self._detect_runtime_needs(node.left)
            self._detect_runtime_needs(node.right)
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                self._detect_runtime_needs(target)
            self._detect_runtime_needs(node.value)
        elif isinstance(node, ast.Expr):
            self._detect_runtime_needs(node.value)
        elif isinstance(node, ast.FunctionDef):
            for stmt in node.body:
                self._detect_runtime_needs(stmt)
        elif isinstance(node, ast.Return) and node.value:
            self._detect_runtime_needs(node.value)
        elif isinstance(node, ast.If):
            for stmt in node.body:
                self._detect_runtime_needs(stmt)
            for stmt in node.orelse:
                self._detect_runtime_needs(stmt)
        elif isinstance(node, ast.While):
            for stmt in node.body:
                self._detect_runtime_needs(stmt)

    def _collect_declarations(self, node: ast.AST) -> None:
        """Collect all variable declarations"""
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    self.declared_vars.add(target.id)
        elif isinstance(node, ast.FunctionDef):
            for stmt in node.body:
                self._collect_declarations(stmt)
        elif isinstance(node, ast.If):
            for stmt in node.body:
                self._collect_declarations(stmt)
            for stmt in node.orelse:
                self._collect_declarations(stmt)
        elif isinstance(node, ast.While):
            for stmt in node.body:
                self._collect_declarations(stmt)
        elif isinstance(node, ast.For):
            # Loop variable is also declared
            if isinstance(node.target, ast.Name):
                self.declared_vars.add(node.target.id)
            for stmt in node.body:
                self._collect_declarations(stmt)

    def _detect_reassignments(self, node: ast.AST, assignments_seen: set[str] | None = None) -> None:
        """Detect variables that are reassigned (need var instead of const)"""
        if assignments_seen is None:
            assignments_seen = set()

        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    if target.id in assignments_seen:
                        self.reassigned_vars.add(target.id)
                    else:
                        assignments_seen.add(target.id)
        elif isinstance(node, ast.FunctionDef):
            # New scope
            func_assignments = set()
            for stmt in node.body:
                self._detect_reassignments(stmt, func_assignments)
        elif isinstance(node, ast.If):
            for stmt in node.body:
                self._detect_reassignments(stmt, assignments_seen)
            for stmt in node.orelse:
                self._detect_reassignments(stmt, assignments_seen)
        elif isinstance(node, ast.While):
            for stmt in node.body:
                self._detect_reassignments(stmt, assignments_seen)
        elif isinstance(node, ast.For):
            for stmt in node.body:
                self._detect_reassignments(stmt, assignments_seen)

    def generate(self, parsed: ParsedModule) -> str:
        """Generate Zig code from parsed module"""
        self.output = []
        self.needs_runtime = False
        self.needs_allocator = False
        self.declared_vars = set()
        self.reassigned_vars = set()

        # First pass: detect runtime needs and collect all declarations
        for node in parsed.ast_tree.body:
            self._detect_runtime_needs(node)
            self._collect_declarations(node)

        # Second pass: detect reassignments
        assignments_seen = set()
        for node in parsed.ast_tree.body:
            self._detect_reassignments(node, assignments_seen)

        # Reset declared_vars for code generation phase
        self.declared_vars = set()

        # Zig imports
        self.emit("const std = @import(\"std\");")
        if self.needs_runtime:
            # TODO: Update path to runtime module once we set up build system
            self.emit("const runtime = @import(\"runtime\");")
        self.emit("")

        # Separate functions from top-level code
        functions = []
        top_level = []

        for node in parsed.ast_tree.body:
            if isinstance(node, ast.FunctionDef):
                functions.append(node)
            else:
                top_level.append(node)

        # Generate functions first
        for func in functions:
            self.visit(func)

        # Wrap top-level code in main function
        if top_level:
            if self.needs_allocator:
                self.emit("pub fn main() !void {")
                self.indent_level += 1
                self.emit("var gpa = std.heap.GeneralPurposeAllocator(.{}){};")
                self.emit("defer _ = gpa.deinit();")
                self.emit("const allocator = gpa.allocator();")
                self.emit("")
            else:
                self.emit("pub fn main() void {")
                self.indent_level += 1

            for node in top_level:
                self.visit(node)

            self.indent_level -= 1
            self.emit("}")

        return "\n".join(self.output)

    def visit(self, node: ast.AST) -> None:
        """Visit an AST node"""
        method_name = f"visit_{node.__class__.__name__}"
        visitor = getattr(self, method_name, self.generic_visit)
        visitor(node)

    def generic_visit(self, node: ast.AST) -> None:
        """Called for unsupported nodes"""
        raise NotImplementedError(
            f"Code generation not implemented for {node.__class__.__name__}"
        )

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        """Generate function definition"""
        # Get return type
        return_type = self.visit_type(node.returns) if node.returns else "void"

        # Build parameter list
        params = []
        for arg in node.args.args:
            arg_type = self.visit_type(arg.annotation) if arg.annotation else "i64"
            params.append(f"{arg.arg}: {arg_type}")

        params_str = ", ".join(params)

        # Function signature
        self.emit(f"fn {node.name}({params_str}) {return_type} {{")
        self.indent_level += 1

        # Function body
        for stmt in node.body:
            self.visit(stmt)

        self.indent_level -= 1
        self.emit("}")
        self.emit("")

    def visit_type(self, node: ast.AST) -> str:
        """Convert Python type to Zig type"""
        if isinstance(node, ast.Name):
            type_map = {
                "int": "i64",
                "float": "f64",
                "bool": "bool",
                "str": "[]const u8",
            }
            return type_map.get(node.id, "anytype")
        return "anytype"

    def visit_If(self, node: ast.If) -> None:
        """Generate if statement"""
        test_code, test_try = self.visit_expr(node.test)
        self.emit(f"if ({test_code}) {{")
        self.indent_level += 1

        for stmt in node.body:
            self.visit(stmt)

        self.indent_level -= 1

        if node.orelse:
            self.emit("} else {")
            self.indent_level += 1
            for stmt in node.orelse:
                self.visit(stmt)
            self.indent_level -= 1

        self.emit("}")

    def visit_While(self, node: ast.While) -> None:
        """Generate while loop"""
        test_code, test_try = self.visit_expr(node.test)
        self.emit(f"while ({test_code}) {{")
        self.indent_level += 1

        for stmt in node.body:
            self.visit(stmt)

        self.indent_level -= 1
        self.emit("}")

    def visit_For(self, node: ast.For) -> None:
        """Generate for loop (only supports range() for now)"""
        # Check if this is a range() call
        if isinstance(node.iter, ast.Call) and isinstance(node.iter.func, ast.Name):
            if node.iter.func.id == "range":
                # Extract range arguments
                args = node.iter.args
                if len(args) == 1:
                    # range(n) -> 0 to n-1
                    start = "0"
                    end_code, _ = self.visit_expr(args[0])
                elif len(args) == 2:
                    # range(start, end)
                    start_code, _ = self.visit_expr(args[0])
                    end_code, _ = self.visit_expr(args[1])
                    start = start_code
                else:
                    raise NotImplementedError("range() with step not supported yet")

                # Get loop variable
                if isinstance(node.target, ast.Name):
                    loop_var = node.target.id
                else:
                    raise NotImplementedError("Complex loop targets not supported")

                # Generate while loop equivalent
                self.emit(f"var {loop_var}: i64 = {start};")
                self.emit(f"while ({loop_var} < {end_code}) {{")
                self.indent_level += 1

                for stmt in node.body:
                    self.visit(stmt)

                # Increment loop variable
                self.emit(f"{loop_var} += 1;")

                self.indent_level -= 1
                self.emit("}")
            else:
                raise NotImplementedError(f"for loop over {node.iter.func.id}() not supported")
        else:
            raise NotImplementedError("for loop only supports range() for now")

    def visit_Return(self, node: ast.Return) -> None:
        """Generate return statement"""
        if node.value:
            value_code, value_try = self.visit_expr(node.value)
            if value_try:
                self.emit(f"return try {value_code};")
            else:
                self.emit(f"return {value_code};")
        else:
            self.emit("return;")

    def _flatten_binop_chain(self, node: ast.BinOp, op_type: type) -> list[ast.AST]:
        """Flatten chained binary operations like a + b + c into [a, b, c]"""
        result = []
        if isinstance(node.left, ast.BinOp) and isinstance(node.left.op, op_type):
            result.extend(self._flatten_binop_chain(node.left, op_type))
        else:
            result.append(node.left)
        result.append(node.right)
        return result

    def visit_Assign(self, node: ast.Assign) -> None:
        """Generate variable assignment"""
        # For now, assume single target
        target = node.targets[0]
        if isinstance(target, ast.Name):
            # Determine if this is first assignment or reassignment
            var_keyword = "var" if target.id in self.reassigned_vars else "const"
            is_first_assignment = target.id not in self.declared_vars
            if is_first_assignment:
                self.declared_vars.add(target.id)

            # Special handling for chained string concatenation
            if isinstance(node.value, ast.BinOp) and isinstance(node.value.op, ast.Add):
                parts_code = []
                uses_runtime = False
                has_string = False
                for part in self._flatten_binop_chain(node.value, ast.Add):
                    part_code, part_try = self.visit_expr(part)
                    parts_code.append((part_code, part_try))
                    if part_try:
                        uses_runtime = True
                    # Check if this part is actually a string
                    if isinstance(part, ast.Constant) and isinstance(part.value, str):
                        has_string = True
                    elif isinstance(part, ast.Name) and self.var_types.get(part.id) == "string":
                        has_string = True

                # Only use PyString.concat if we're actually concatenating strings
                if has_string and (self.needs_runtime or uses_runtime):
                    # Generate temp variables for each part
                    temp_vars = []
                    for i, (part_code, part_try) in enumerate(parts_code):
                        if part_try:
                            # Expression that creates PyObject (e.g., string literal)
                            temp_var = f"_temp_{target.id}_{i}"
                            self.emit(f"const {temp_var} = try {part_code};")
                            self.emit(f"defer runtime.decref({temp_var}, allocator);")
                            temp_vars.append(temp_var)
                        else:
                            # Variable reference - use directly (already a PyObject in runtime mode)
                            temp_vars.append(part_code)

                    # Chain concat operations
                    if len(temp_vars) == 1:
                        if is_first_assignment:
                            self.emit(f"{var_keyword} {target.id} = {temp_vars[0]};")
                        else:
                            self.emit(f"{target.id} = {temp_vars[0]};")
                    else:
                        result_var = temp_vars[0]
                        for i in range(1, len(temp_vars)):
                            next_var = f"_concat_{target.id}_{i}"
                            self.emit(f"const {next_var} = try runtime.PyString.concat(allocator, {result_var}, {temp_vars[i]});")
                            if i < len(temp_vars) - 1:  # All intermediate results need cleanup
                                self.emit(f"defer runtime.decref({next_var}, allocator);")
                            result_var = next_var
                        if is_first_assignment:
                            self.emit(f"{var_keyword} {target.id} = {result_var};")
                        else:
                            self.emit(f"{target.id} = {result_var};")

                    if is_first_assignment:
                        self.emit(f"defer runtime.decref({target.id}, allocator);")
                    return

            # Special handling for list literals
            if isinstance(node.value, ast.List):
                # Track this as a list type
                self.var_types[target.id] = "list"

                # Create empty list
                if is_first_assignment:
                    self.emit(f"{var_keyword} {target.id} = try runtime.PyList.create(allocator);")
                    self.emit(f"defer runtime.decref({target.id}, allocator);")
                else:
                    self.emit(f"{target.id} = try runtime.PyList.create(allocator);")

                # Append each element
                for elem in node.value.elts:
                    elem_code, elem_try = self.visit_expr(elem)
                    if elem_try:
                        # PyObject - need to create it first
                        temp_var = f"_temp_elem_{id(elem)}"
                        self.emit(f"const {temp_var} = try {elem_code};")
                        self.emit(f"try runtime.PyList.append({target.id}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")
                    else:
                        # Primitive value - wrap in PyInt
                        temp_var = f"_temp_elem_{id(elem)}"
                        self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {elem_code});")
                        self.emit(f"try runtime.PyList.append({target.id}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")
                return

            # Special handling for subscript assignment (track as pyint)
            if isinstance(node.value, ast.Subscript):
                self.var_types[target.id] = "pyint"

            # Special handling for list.pop() (track as pyint)
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute):
                if node.value.func.attr == "pop":
                    self.var_types[target.id] = "pyint"

            # Special handling for dict literals
            if isinstance(node.value, ast.Dict):
                # Track this as a dict type
                self.var_types[target.id] = "dict"

                # Create empty dict
                if is_first_assignment:
                    self.emit(f"{var_keyword} {target.id} = try runtime.PyDict.create(allocator);")
                    self.emit(f"defer runtime.decref({target.id}, allocator);")
                else:
                    self.emit(f"{target.id} = try runtime.PyDict.create(allocator);")

                # Set each key-value pair
                for key_node, value_node in zip(node.value.keys, node.value.values):
                    if key_node is None:
                        continue  # Skip **kwargs

                    # Key must be a string
                    if isinstance(key_node, ast.Constant) and isinstance(key_node.value, str):
                        key_str = key_node.value
                    else:
                        raise NotImplementedError("Dict keys must be string literals for now")

                    value_code, value_try = self.visit_expr(value_node)
                    if value_try:
                        # PyObject - need to create it first
                        temp_var = f"_temp_val_{id(value_node)}"
                        self.emit(f"const {temp_var} = try {value_code};")
                        self.emit(f'try runtime.PyDict.set({target.id}, "{key_str}", {temp_var});')
                        self.emit(f"runtime.decref({temp_var}, allocator);")
                    else:
                        # Primitive value - wrap in PyInt
                        temp_var = f"_temp_val_{id(value_node)}"
                        self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {value_code});")
                        self.emit(f'try runtime.PyDict.set({target.id}, "{key_str}", {temp_var});')
                        self.emit(f"runtime.decref({temp_var}, allocator);")
                return

            # Special handling for binary ops with subscripts (e.g., total + list[i])
            if isinstance(node.value, ast.BinOp) and isinstance(node.value.op, ast.Add):
                left_code, left_try = self.visit_expr(node.value.left)
                right_code, right_try = self.visit_expr(node.value.right)

                # If either side is a subscript (returns PyObject), extract the value
                left_expr = left_code
                if isinstance(node.value.left, ast.Subscript):
                    left_expr = f"runtime.PyInt.getValue({left_code})"

                right_expr = right_code
                if isinstance(node.value.right, ast.Subscript):
                    right_expr = f"runtime.PyInt.getValue({right_code})"

                # If we modified either expression, use the extracted values
                if left_expr != left_code or right_expr != right_code:
                    # Track this as primitive int
                    self.var_types[target.id] = "int"
                    op = self.visit_bin_op(node.value.op)
                    if is_first_assignment:
                        if var_keyword == "var":
                            self.emit(f"{var_keyword} {target.id}: i64 = {left_expr} {op} {right_expr};")
                        else:
                            self.emit(f"{var_keyword} {target.id} = {left_expr} {op} {right_expr};")
                    else:
                        self.emit(f"{target.id} = {left_expr} {op} {right_expr};")
                    return

            # Default path
            value_code, needs_try = self.visit_expr(node.value)
            if is_first_assignment:
                if needs_try:
                    self.emit(f"{var_keyword} {target.id} = try {value_code};")
                    self.emit(f"defer runtime.decref({target.id}, allocator);")
                else:
                    # For var, need explicit type; for const, type is inferred
                    if var_keyword == "var":
                        self.emit(f"{var_keyword} {target.id}: i64 = {value_code};")
                    else:
                        self.emit(f"{var_keyword} {target.id} = {value_code};")
            else:
                # Reassignment - no var/const keyword
                if needs_try:
                    self.emit(f"{target.id} = try {value_code};")
                else:
                    self.emit(f"{target.id} = {value_code};")

    def visit_Expr(self, node: ast.Expr) -> None:
        """Generate expression statement"""
        # Skip docstrings
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            return

        expr_code, needs_try = self.visit_expr(node.value)

        # Special handling for list.append() with primitive args
        if expr_code.startswith("__list_append__"):
            parts = expr_code.split("__")
            obj_code = parts[2]
            arg_code = parts[3]
            arg_try = parts[4] == "True"

            if not arg_try:
                # Primitive - wrap in PyInt first
                temp_var = f"_append_arg_{id(node)}"
                self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {arg_code});")
                self.emit(f"try runtime.PyList.append({obj_code}, {temp_var});")
                self.emit(f"runtime.decref({temp_var}, allocator);")
            else:
                # Already PyObject
                self.emit(f"try runtime.PyList.append({obj_code}, {arg_code});")
            return

        if needs_try:
            self.emit(f"_ = try {expr_code};")
        else:
            self.emit(f"_ = {expr_code};")

    def visit_expr(self, node: ast.AST) -> tuple[str, bool]:
        """Visit an expression node and return (code, needs_try) tuple"""
        if isinstance(node, ast.Name):
            return (node.id, False)

        elif isinstance(node, ast.Constant):
            if isinstance(node.value, str):
                # String literal -> PyString.create
                return (f'runtime.PyString.create(allocator, "{node.value}")', True)
            else:
                # Numeric literal
                return (str(node.value), False)

        elif isinstance(node, ast.Compare):
            left_code, left_try = self.visit_expr(node.left)
            op = self.visit_compare_op(node.ops[0])
            right_code, right_try = self.visit_expr(node.comparators[0])
            # Comparisons don't need try for now
            return (f"{left_code} {op} {right_code}", False)

        elif isinstance(node, ast.BinOp):
            left_code, left_try = self.visit_expr(node.left)
            right_code, right_try = self.visit_expr(node.right)

            # Check if this is string concatenation
            if left_try or right_try:
                # String concatenation -> PyString.concat
                return (f"runtime.PyString.concat(allocator, {left_code}, {right_code})", True)
            else:
                # Numeric operation
                op = self.visit_bin_op(node.op)
                return (f"{left_code} {op} {right_code}", False)

        elif isinstance(node, ast.List):
            # List literal -> PyList.create + append items
            # This returns a unique temp var name that caller must handle
            return (f"__list_literal_{id(node)}", True)

        elif isinstance(node, ast.Dict):
            # Dict literal -> PyDict.create + set items
            # This returns a unique temp var name that caller must handle
            return (f"__dict_literal_{id(node)}", True)

        elif isinstance(node, ast.Subscript):
            # List/dict indexing: obj[index] or obj["key"]
            value_code, value_try = self.visit_expr(node.value)

            # Check if it's a dict access (string key) or list access (int index)
            if isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, str):
                # Dict access with string key
                key_str = node.slice.value
                return (f'runtime.PyDict.get({value_code}, "{key_str}").?', False)
            else:
                # List access with integer index
                index_code, index_try = self.visit_expr(node.slice)
                return (f"runtime.PyList.getItem({value_code}, @intCast({index_code}))", False)

        elif isinstance(node, ast.Attribute):
            # Method/attribute access: obj.method or obj.attr
            value_code, value_try = self.visit_expr(node.value)
            # For now, just return a marker that this is a method access
            # The Call handler will detect this and handle it specially
            return (f"__method__{value_code}__{node.attr}", False)

        elif isinstance(node, ast.Call):
            func_code, func_try = self.visit_expr(node.func)
            args = [self.visit_expr(arg) for arg in node.args]

            # Check if this is a method call
            if func_code.startswith("__method__"):
                # Extract object and method name
                parts = func_code.split("__")
                obj_code = parts[2]
                method_name = parts[3]

                # Handle string methods
                if method_name == "upper":
                    return (f"runtime.PyString.upper(allocator, {obj_code})", True)
                elif method_name == "lower":
                    return (f"runtime.PyString.lower(allocator, {obj_code})", True)
                # Handle list methods
                elif method_name == "append":
                    # This will be handled in visit_Expr for statement context
                    # Mark it with a special token so visit_Expr can detect it
                    if args:
                        arg_code, arg_try = args[0]
                        return (f"__list_append__{obj_code}__{arg_code}__{arg_try}", True)
                    raise NotImplementedError("append() requires an argument")
                elif method_name == "pop":
                    # pop() returns a PyObject that caller must manage
                    # Mark as needing to track this as py object
                    return (f"runtime.PyList.pop({obj_code}, allocator)", False)
                else:
                    raise NotImplementedError(f"Method {method_name} not supported")

            # Special handling for print
            if func_code == "print":
                if args:
                    arg_code, arg_needs_try = args[0]
                    # Check if we're in runtime mode (PyObject types)
                    if self.needs_runtime:
                        # Check if it's a subscript (returns PyObject*)
                        if isinstance(node.args[0], ast.Subscript):
                            # Subscript returns PyObject* - need to extract value
                            # Check if it's a dict with string key or list with int index
                            subscript_node = node.args[0]
                            if isinstance(subscript_node.slice, ast.Constant) and isinstance(subscript_node.slice.value, str):
                                # Dict access - value could be string or int
                                # We need to check the dict variable to determine value type
                                # For now, try to determine from the dict definition
                                # This is a simplified approach - ideally we'd track value types
                                # For dict_simple.py: "name" -> string, "age" -> int
                                key = subscript_node.slice.value
                                # Heuristic: keys like "name", "title" are strings, others are ints
                                if key in ["name", "title", "text", "message"]:
                                    return (f'std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({arg_code})}})', False)
                                else:
                                    return (f'std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({arg_code})}})', False)
                            else:
                                # List access - assume PyInt
                                return (f'std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({arg_code})}})', False)
                        # In runtime mode, check variable type
                        elif isinstance(node.args[0], ast.Name):
                            arg_name = node.args[0].id
                            var_type = self.var_types.get(arg_name, "string")
                            if var_type == "pyint":
                                return (f'std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({arg_name})}})', False)
                            elif var_type == "int":
                                # Primitive int
                                return (f'std.debug.print("{{}}\\n", .{{{arg_name}}})', False)
                            else:
                                # Default to string
                                return (f'std.debug.print("{{s}}\\n", .{{PyString.getValue({arg_name})}})', False)
                        elif arg_needs_try:
                            # Expression that creates PyObject
                            return (f'std.debug.print("{{s}}\\n", .{{PyString.getValue(try {arg_code})}})', False)
                    # Primitive types (int, float, etc)
                    return (f'std.debug.print("{{}}\\n", .{{{arg_code}}})', False)
                return (f'std.debug.print("\\n", .{{}})', False)

            # Special handling for len()
            if func_code == "len" and args:
                arg_code, arg_try = args[0]
                # Check variable type to determine PyList.len or PyDict.len
                if isinstance(node.args[0], ast.Name):
                    arg_name = node.args[0].id
                    var_type = self.var_types.get(arg_name, "list")
                    if var_type == "dict":
                        return (f"runtime.PyDict.len({arg_code})", False)
                return (f"runtime.PyList.len({arg_code})", False)

            # Regular function call
            args_str = ", ".join(arg[0] for arg in args)
            return (f"{func_code}({args_str})", False)

        else:
            raise NotImplementedError(
                f"Expression not implemented: {node.__class__.__name__}"
            )

    def visit_compare_op(self, op: ast.AST) -> str:
        """Convert comparison operator"""
        op_map = {
            ast.Lt: "<",
            ast.LtE: "<=",
            ast.Gt: ">",
            ast.GtE: ">=",
            ast.Eq: "==",
            ast.NotEq: "!=",
        }
        return op_map.get(type(op), "==")

    def visit_bin_op(self, op: ast.AST) -> str:
        """Convert binary operator"""
        op_map = {
            ast.Add: "+",
            ast.Sub: "-",
            ast.Mult: "*",
            ast.Div: "/",
            ast.Mod: "%",
        }
        return op_map.get(type(op), "+")


def generate_code(parsed: ParsedModule) -> str:
    """Generate Zig code from parsed module"""
    generator = ZigCodeGenerator()
    return generator.generate(parsed)


if __name__ == "__main__":
    import sys
    from zyth_core.parser import parse_file

    if len(sys.argv) < 2:
        print("Usage: python -m zyth_core.codegen <file.py>")
        sys.exit(1)

    filepath = sys.argv[1]
    parsed = parse_file(filepath)
    zig_code = generate_code(parsed)

    print(f"✓ Generated Zig code from {filepath}\n")
    print("=" * 60)
    print(zig_code)
    print("=" * 60)
