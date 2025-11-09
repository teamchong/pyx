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

    def _detect_reassignments(self, node: ast.AST) -> None:
        """Detect variables that are reassigned (need var instead of const)"""
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    if target.id in self.declared_vars:
                        self.reassigned_vars.add(target.id)
                    else:
                        self.declared_vars.add(target.id)
        elif isinstance(node, ast.FunctionDef):
            for stmt in node.body:
                self._detect_reassignments(stmt)
        elif isinstance(node, ast.If):
            for stmt in node.body:
                self._detect_reassignments(stmt)
            for stmt in node.orelse:
                self._detect_reassignments(stmt)
        elif isinstance(node, ast.While):
            for stmt in node.body:
                self._detect_reassignments(stmt)

    def generate(self, parsed: ParsedModule) -> str:
        """Generate Zig code from parsed module"""
        self.output = []
        self.needs_runtime = False
        self.needs_allocator = False
        self.declared_vars = set()
        self.reassigned_vars = set()

        # First pass: detect runtime needs and variable reassignments
        for node in parsed.ast_tree.body:
            self._detect_runtime_needs(node)
            self._detect_reassignments(node)

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
                for part in self._flatten_binop_chain(node.value, ast.Add):
                    part_code, part_try = self.visit_expr(part)
                    parts_code.append((part_code, part_try))
                    if part_try:
                        uses_runtime = True

                # If we're in runtime mode (strings), use PyObject concat
                if self.needs_runtime or uses_runtime:
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

        elif isinstance(node, ast.Call):
            func_code, func_try = self.visit_expr(node.func)
            args = [self.visit_expr(arg) for arg in node.args]

            # Special handling for print
            if func_code == "print":
                if args:
                    arg_code, arg_needs_try = args[0]
                    # Check if we're in runtime mode (PyObject types)
                    if self.needs_runtime:
                        # In runtime mode, assume variables are PyObjects
                        if isinstance(node.args[0], ast.Name):
                            arg_name = node.args[0].id
                            return (f'std.debug.print("{{s}}\\n", .{{PyString.getValue({arg_name})}})', False)
                        elif arg_needs_try:
                            # Expression that creates PyObject
                            return (f'std.debug.print("{{s}}\\n", .{{PyString.getValue(try {arg_code})}})', False)
                    # Primitive types (int, float, etc)
                    return (f'std.debug.print("{{}}\\n", .{{{arg_code}}})', False)
                return (f'std.debug.print("\\n", .{{}})', False)

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
