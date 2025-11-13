"""
Zyth Code Generator - Converts Python AST to Zig code
"""
import ast
from typing import List, Dict, Optional
from dataclasses import dataclass
from core.parser import ParsedModule
from core.method_registry import get_method_info, ReturnType
from core.codegen.helpers import CodegenHelpers
from core.codegen.expressions import ExpressionVisitor


@dataclass
class ClassInfo:
    """Metadata for a class definition"""
    name: str
    base_class: Optional[str]  # Parent class name (None for no inheritance)
    fields: Dict[str, str]  # field_name -> type ("int", "string", etc.)
    methods: Dict[str, dict]  # method_name -> signature dict
    method_nodes: Dict[str, ast.FunctionDef]  # method AST nodes for inheritance
    init_params: List[tuple[str, str]]  # (param_name, param_type)


class ZigCodeGenerator(CodegenHelpers, ExpressionVisitor):
    """Generates Zig code from Python AST"""

    def __init__(self, imported_modules: Optional[Dict[str, ParsedModule]] = None) -> None:
        self.indent_level = 0
        self.output: List[str] = []
        self.needs_runtime = False  # Track if we need PyObject runtime
        self.needs_allocator = False  # Track if we need allocator
        self.declared_vars: set[str] = set()  # Track declared variables
        self.reassigned_vars: set[str] = set()  # Track variables that are reassigned
        self.var_types: dict[str, str] = {}  # Track variable types: "int", "string", "list", "pyint", or class names
        self.list_element_types: dict[str, str] = {}  # Track list element types: "string", "int"
        self.tuple_element_types: dict[str, str] = {}  # Track tuple element types: "string", "int"
        self.function_signatures: dict[str, dict] = {}  # Track function signatures for proper calling
        self.class_definitions: dict[str, ClassInfo] = {}  # Track class definitions  # type: ignore[assignment]
        self.current_class: Optional[str] = None  # Track which class we're currently in
        self.imported_modules: Dict[str, ParsedModule] = imported_modules or {}  # Track imported modules
        self.module_functions: Dict[str, Dict[str, dict]] = {}  # Track module.function signatures
        self.function_params: set[str] = set()  # Track current function parameters
        self.vars_assigned_from_params: set[str] = set()  # Track variables initially assigned from parameters

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
        elif isinstance(node, ast.Tuple):
            # Tuple literal requires runtime
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
        elif isinstance(node, ast.For):
            # Check the iterator and body for runtime needs
            self._detect_runtime_needs(node.iter)
            for stmt in node.body:
                self._detect_runtime_needs(stmt)
        elif isinstance(node, ast.Call):
            # Check function arguments for runtime needs
            for arg in node.args:
                self._detect_runtime_needs(arg)

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
        elif isinstance(node, ast.AugAssign):
            # Augmented assignment is always a reassignment
            if isinstance(node.target, ast.Name):
                if node.target.id in assignments_seen:
                    self.reassigned_vars.add(node.target.id)
                else:
                    # First assignment followed by augmented assignment
                    assignments_seen.add(node.target.id)
                    self.reassigned_vars.add(node.target.id)
        elif isinstance(node, ast.FunctionDef):
            # New scope
            func_assignments: set[str] = set()
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

        # Second pass: detect reassignments in main module
        assignments_seen: set[str] = set()
        for node in parsed.ast_tree.body:
            self._detect_reassignments(node, assignments_seen)

        # Also detect reassignments in imported modules
        for module_name, module in self.imported_modules.items():
            module_assignments_seen: set[str] = set()
            for node in module.ast_tree.body:
                self._detect_reassignments(node, module_assignments_seen)

        # Reset declared_vars for code generation phase
        self.declared_vars = set()
        # Separate classes, functions, and top-level code
        classes = []
        functions = []
        top_level = []

        for node in parsed.ast_tree.body:
            if isinstance(node, ast.ClassDef):
                classes.append(node)
            elif isinstance(node, ast.FunctionDef):
                functions.append(node)
            else:
                top_level.append(node)

        # Pre-analyze classes to populate class_definitions
        # (This is done during visit_ClassDef, but we need to know class names before)
        for cls in classes:
            # Extract base class if present
            cls_base = None
            if cls.bases and isinstance(cls.bases[0], ast.Name):
                cls_base = cls.bases[0].id

            # Check if class has string-typed parameters (need runtime)
            for item in cls.body:
                if isinstance(item, ast.FunctionDef) and item.name == "__init__":
                    for arg in item.args.args[1:]:  # Skip self
                        if arg.annotation and isinstance(arg.annotation, ast.Name):
                            if arg.annotation.id == "str":
                                self.needs_runtime = True
                                self.needs_allocator = True
            # Just register the class name so we can detect class instantiation
            self.class_definitions[cls.name] = ClassInfo(
                name=cls.name,
                base_class=cls_base,
                fields={},
                methods={},
                method_nodes={},
                init_params=[]
            )

        # Zig imports
        self.emit("const std = @import(\"std\");")
        if self.needs_runtime:
            # TODO: Update path to runtime module once we set up build system
            self.emit("const runtime = @import(\"runtime\");")
        self.emit("")
        # Pre-analyze functions to populate function_signatures before generating code
        for func in functions:
            needs_allocator = self._function_needs_allocator(func)
            returns_pyobject = False
            if func.returns and isinstance(func.returns, ast.Name):
                if func.returns.id in ["str", "list", "dict"]:
                    returns_pyobject = True
            self.function_signatures[func.name] = {
                "needs_allocator": needs_allocator,
                "param_count": len(func.args.args),
                "returns_pyobject": returns_pyobject,
            }

        # Pre-analyze imported modules to extract function signatures
        for module_name, module in self.imported_modules.items():
            module_funcs = {}
            for node in module.ast_tree.body:
                if isinstance(node, ast.FunctionDef):
                    needs_allocator = self._function_needs_allocator(node)
                    returns_pyobject = False
                    if node.returns and isinstance(node.returns, ast.Name):
                        if node.returns.id in ["str", "list", "dict"]:
                            returns_pyobject = True
                    module_funcs[node.name] = {
                        "needs_allocator": needs_allocator,
                        "param_count": len(node.args.args),
                        "returns_pyobject": returns_pyobject,
                        "node": node,
                    }
            self.module_functions[module_name] = module_funcs

        # Check if top-level code needs allocator
        # Need allocator if: (1) creates runtime objects OR (2) calls functions/classes that need allocator
        top_level_needs_allocator = False
        for node in top_level:
            # Skip docstrings (they're just comments, not executed code)
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                continue

            if self._stmt_needs_runtime(node):
                top_level_needs_allocator = True
                break
            # Check if calling a function or class constructor that needs allocator
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call):
                if isinstance(node.value.func, ast.Name):
                    func_name = node.value.func.id
                    # Check if it's a function call
                    if func_name in self.function_signatures:
                        if self.function_signatures[func_name]["needs_allocator"]:
                            top_level_needs_allocator = True
                            break
                    # Check if it's a class instantiation (always needs allocator)
                    if func_name in self.class_definitions:
                        top_level_needs_allocator = True
                        break
                # Check if calling a module function
                elif isinstance(node.value.func, ast.Attribute):
                    if isinstance(node.value.func.value, ast.Name):
                        module_name = node.value.func.value.id
                        if module_name in self.module_functions:
                            func_name = node.value.func.attr
                            if func_name in self.module_functions[module_name]:
                                # Module function - check if it needs allocator
                                if self.module_functions[module_name][func_name]["needs_allocator"]:
                                    top_level_needs_allocator = True
                                    break
            # Check if calling a method on an instance or module function
            elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
                if isinstance(node.value.func, ast.Attribute):
                    # Check if this is a module function call
                    if isinstance(node.value.func.value, ast.Name):
                        module_name = node.value.func.value.id
                        if module_name in self.module_functions:
                            func_name = node.value.func.attr
                            if func_name in self.module_functions[module_name]:
                                # Module function - check if it needs allocator
                                if self.module_functions[module_name][func_name]["needs_allocator"]:
                                    top_level_needs_allocator = True
                                    break
                                else:
                                    continue  # Module function doesn't need allocator
                    # Method call on instance - might need allocator
                    top_level_needs_allocator = True
                    break

        # Generate classes
        for cls in classes:
            self.visit(cls)

        # Generate functions
        for func in functions:
            self.visit(func)

        # Generate module namespace structs
        for module_name, module_funcs in self.module_functions.items():
            self.emit(f"const {module_name} = struct {{")
            self.indent_level += 1

            # Temporarily add module functions to function_signatures so visit_FunctionDef works
            for func_name, func_sig in module_funcs.items():
                self.function_signatures[func_name] = {
                    "needs_allocator": func_sig["needs_allocator"],
                    "param_count": func_sig["param_count"],
                    "returns_pyobject": func_sig["returns_pyobject"],
                }

            for func_name, func_sig in module_funcs.items():
                func_node = func_sig["node"]
                if isinstance(func_node, ast.FunctionDef):
                    self.visit_FunctionDef(func_node)

            # Remove module functions from function_signatures
            for func_name in module_funcs.keys():
                del self.function_signatures[func_name]

            self.indent_level -= 1
            self.emit("};")
            self.emit("")

        # Wrap top-level code in main function
        if top_level:
            if top_level_needs_allocator:
                self.emit("pub fn main() !void {")
                self.indent_level += 1
                self.emit("var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false }){};")
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

    def visit_Import(self, node: ast.Import) -> None:
        """Handle import statements - no-op since modules are pre-analyzed"""
        pass

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        """Handle from...import statements - stub implementation"""
        # For now, just silently accept imports without generating code
        # This allows 'import pytest' and similar to work
        pass

    def _function_needs_allocator(self, node: ast.FunctionDef) -> bool:
        """Check if function needs allocator parameter

        Functions need allocator only if they:
        - Create new PyObjects (strings, lists, dicts)
        - Call methods that need allocator
        - Return runtime types

        Just having runtime parameters doesn't require allocator.
        """
        # Check if function body creates/modifies runtime objects
        for stmt in node.body:
            if self._stmt_needs_runtime(stmt):
                return True
        # Check if return type is runtime type (will need to create PyObject)
        if node.returns and isinstance(node.returns, ast.Name):
            if node.returns.id in ["str", "list", "dict"]:
                return True
        return False

    def _stmt_needs_runtime(self, node: ast.AST) -> bool:
        """Check if a statement needs runtime"""
        if isinstance(node, ast.Expr):
            return self._expr_needs_runtime(node.value)
        elif isinstance(node, ast.Assign):
            return self._expr_needs_runtime(node.value)
        elif isinstance(node, ast.Return):
            if node.value:
                return self._expr_needs_runtime(node.value)
        elif isinstance(node, ast.If):
            for stmt in node.body:
                if self._stmt_needs_runtime(stmt):
                    return True
            for stmt in node.orelse:
                if self._stmt_needs_runtime(stmt):
                    return True
        elif isinstance(node, ast.While):
            for stmt in node.body:
                if self._stmt_needs_runtime(stmt):
                    return True
        elif isinstance(node, ast.For):
            for stmt in node.body:
                if self._stmt_needs_runtime(stmt):
                    return True
        return False

    def _expr_needs_runtime(self, node: ast.AST) -> bool:
        """Check if an expression needs runtime"""
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return True
        elif isinstance(node, ast.List) or isinstance(node, ast.Dict) or isinstance(node, ast.Tuple):
            return True
        elif isinstance(node, ast.BinOp):
            if isinstance(node.op, ast.Add):
                # Check if it's string concatenation
                if self._expr_needs_runtime(node.left) or self._expr_needs_runtime(node.right):
                    return True
        elif isinstance(node, ast.Call):
            if isinstance(node.func, ast.Attribute):
                # Check if this is a module function call (doesn't need runtime)
                if isinstance(node.func.value, ast.Name):
                    module_name = node.func.value.id
                    if module_name in self.module_functions:
                        return False  # Module function calls don't need runtime
                # Method calls on runtime types
                return True
            # Check if print() or other built-in functions have runtime args
            for arg in node.args:
                if self._expr_needs_runtime(arg):
                    return True
        return False

    def _function_uses_error_operations(self, node: ast.FunctionDef) -> bool:
        """Check if function uses operations that can throw errors (subscripts, method calls, etc.)"""
        for stmt in ast.walk(node):
            # Subscript operations (list[i], dict[key]) return error unions
            if isinstance(stmt, ast.Subscript):
                return True
            # Method calls on PyObjects may return error unions
            if isinstance(stmt, ast.Call) and isinstance(stmt.func, ast.Attribute):
                return True
        return False

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        """Generate function definition"""
        # Get pre-computed signature
        sig = self.function_signatures[node.name]
        needs_allocator = sig["needs_allocator"]

        # Determine if function needs error union
        # Functions need error union if they use allocator OR error-returning operations
        needs_error_union = needs_allocator or self._function_uses_error_operations(node)

        # Get return type
        return_type = self.visit_type(node.returns, for_runtime=needs_allocator) if node.returns else "void"
        if needs_error_union and return_type != "void":
            return_type = f"!{return_type}"
        elif needs_error_union:
            return_type = "!void"

        # Update signature with full return type
        sig["return_type"] = return_type

        # Build parameter list
        params = []
        if needs_allocator:
            params.append("allocator: std.mem.Allocator")

        for arg in node.args.args:
            arg_type = self.visit_type(arg.annotation, for_runtime=needs_allocator) if arg.annotation else "i64"
            params.append(f"{arg.arg}: {arg_type}")

        params_str = ", ".join(params)

        # Function signature
        self.emit(f"fn {node.name}({params_str}) {return_type} {{")
        self.indent_level += 1

        # Track parameter types and names for use in function body
        self.function_params = set()
        for arg in node.args.args:
            self.function_params.add(arg.arg)
            if arg.annotation and isinstance(arg.annotation, ast.Name):
                if arg.annotation.id == "str":
                    self.var_types[arg.arg] = "string"
                elif arg.annotation.id == "list":
                    self.var_types[arg.arg] = "list"
                elif arg.annotation.id == "dict":
                    self.var_types[arg.arg] = "dict"
                elif arg.annotation.id == "int":
                    self.var_types[arg.arg] = "int"

        # Function body
        for stmt in node.body:
            self.visit(stmt)

        self.indent_level -= 1
        self.emit("}")
        self.emit("")

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        """Generate class definition as Zig struct"""
        class_name = node.name
        self.current_class = class_name

        # Extract base class (support single inheritance only)
        base_class: Optional[str] = None
        if node.bases:
            if len(node.bases) > 1:
                raise NotImplementedError("Multiple inheritance not supported")
            if isinstance(node.bases[0], ast.Name):
                base_class = node.bases[0].id

        # Extract __init__ method to determine fields and parameters
        init_method = None
        methods = []
        fields: Dict[str, str] = {}
        init_params: List[tuple[str, str]] = []

        for item in node.body:
            if isinstance(item, ast.FunctionDef):
                if item.name == "__init__":
                    init_method = item
                    # Extract init parameters (skip 'self')
                    for arg in item.args.args[1:]:  # Skip self
                        param_type = "i64"  # Default to int
                        if arg.annotation and isinstance(arg.annotation, ast.Name):
                            param_type = self._map_python_type_to_zig(arg.annotation.id)
                        init_params.append((arg.arg, param_type))

                    # Extract fields from self.field = value assignments
                    for stmt in item.body:
                        if isinstance(stmt, ast.Assign):
                            for target in stmt.targets:
                                if isinstance(target, ast.Attribute):
                                    if isinstance(target.value, ast.Name) and target.value.id == "self":
                                        # This is a field assignment: self.field = value
                                        field_name = target.attr
                                        # Infer type from the value
                                        field_type = self._infer_field_type(stmt.value, init_params)
                                        fields[field_name] = field_type
                else:
                    methods.append(item)

        # Analyze method signatures and store AST nodes
        method_sigs = {}
        method_nodes = {}
        for method in methods:
            return_type = "void"
            needs_allocator = False
            if method.returns and isinstance(method.returns, ast.Name):
                return_type = self._map_python_type_to_zig(method.returns.id)
                if return_type == "*runtime.PyObject":
                    needs_allocator = True
            method_sigs[method.name] = {
                "return_type": return_type,
                "needs_allocator": needs_allocator
            }
            method_nodes[method.name] = method

        # Store class metadata
        self.class_definitions[class_name] = ClassInfo(
            name=class_name,
            base_class=base_class,
            fields=fields,
            methods=method_sigs,
            method_nodes=method_nodes,
            init_params=init_params
        )

        # Generate Zig struct
        self.emit(f"const {class_name} = struct {{")
        self.indent_level += 1

        # Generate field declarations
        for field_name, field_type in fields.items():
            self.emit(f"{field_name}: {field_type},")

        if fields:
            self.emit("")

        # Generate init function (constructor)
        if init_method:
            self._generate_init_function(class_name, init_method, init_params, fields)

        # Generate deinit function (destructor)
        self._generate_deinit_function(class_name, fields)

        # Generate methods
        for method in methods:
            self._generate_method(class_name, method)


        # Generate parent methods that are not overridden
        child_method_names = {m.name for m in methods}
        if base_class:
            parent_info = self.class_definitions[base_class]
            for parent_method_name, parent_method_node in parent_info.method_nodes.items():
                if parent_method_name not in child_method_names and parent_method_name not in ["init", "deinit"]:
                    # Generate inherited method with child class type
                    self._generate_method(class_name, parent_method_node)

        self.indent_level -= 1
        self.emit("};")
        self.emit("")

        self.current_class = None

    def _map_python_type_to_zig(self, python_type: str) -> str:
        """Map Python type annotation to Zig type"""
        type_map = {
            "int": "i64",
            "float": "f64",
            "bool": "bool",
            "str": "*runtime.PyObject",
        }
        return type_map.get(python_type, "i64")

    def _infer_field_type(self, value_node: ast.AST, init_params: List[tuple[str, str]]) -> str:
        """Infer field type from assignment value"""
        # If value is a parameter, use parameter type
        if isinstance(value_node, ast.Name):
            param_name = value_node.id
            for pname, ptype in init_params:
                if pname == param_name:
                    return ptype
        # If value is a constant, infer from constant type
        elif isinstance(value_node, ast.Constant):
            if isinstance(value_node.value, int):
                return "i64"
            elif isinstance(value_node.value, str):
                return "*runtime.PyObject"
        # Default to i64
        return "i64"

    def _generate_init_function(self, class_name: str, init_method: ast.FunctionDef,
                                init_params: List[tuple[str, str]], fields: Dict[str, str]) -> None:
        """Generate the init (constructor) function"""
        # Build parameter list
        params = ["allocator: std.mem.Allocator"]
        for param_name, param_type in init_params:
            params.append(f"{param_name}: {param_type}")

        params_str = ", ".join(params)

        self.emit(f"pub fn init({params_str}) !*{class_name} {{")
        self.indent_level += 1

        # Create instance
        self.emit(f"const instance = try allocator.create({class_name});")

        # Generate field initializations from __init__ body
        for stmt in init_method.body:
            if isinstance(stmt, ast.Assign):
                for target in stmt.targets:
                    if isinstance(target, ast.Attribute):
                        if isinstance(target.value, ast.Name) and target.value.id == "self":
                            field_name = target.attr
                            # Generate field assignment
                            value_code, _ = self.visit_expr(stmt.value)
                            self.emit(f"instance.{field_name} = {value_code};")

        self.emit(f"return instance;")

        self.indent_level -= 1
        self.emit("}")
        self.emit("")

    def _generate_deinit_function(self, class_name: str, fields: Dict[str, str]) -> None:
        """Generate the deinit (destructor) function"""
        self.emit(f"pub fn deinit(self: *{class_name}, allocator: std.mem.Allocator) void {{")
        self.indent_level += 1

        # Decref PyObject fields before destroying instance
        for field_name, field_type in fields.items():
            if field_type == "*runtime.PyObject":
                self.emit(f"runtime.decref(self.{field_name}, allocator);")

        self.emit("allocator.destroy(self);")

        self.indent_level -= 1
        self.emit("}")
        self.emit("")


    def _uses_variable(self, node: ast.AST, var_name: str) -> bool:
        """Check if an AST node uses a specific variable"""
        for child in ast.walk(node):
            if isinstance(child, ast.Name) and child.id == var_name:
                return True
            elif isinstance(child, ast.Attribute) and isinstance(child.value, ast.Name):
                if child.value.id == var_name:
                    return True
        return False

    def _generate_method(self, class_name: str, method: ast.FunctionDef) -> None:
        """Generate an instance method"""
        # Get return type
        return_type = "void"
        needs_error_union = False
        needs_allocator_param = False

        if method.returns and isinstance(method.returns, ast.Name):
            return_type = self._map_python_type_to_zig(method.returns.id)
            # String/list/dict returns need error union and allocator
            if return_type == "*runtime.PyObject":
                needs_error_union = True
                needs_allocator_param = True

        # Build parameter list (self + other params)
        # Check if method body uses self
        uses_self = any(self._uses_variable(stmt, "self") for stmt in method.body)
        
        # Build parameter list (prefix self with _ if unused)
        self_param = "_: *{}" if not uses_self else "self: *{}"
        params = [self_param.format(class_name)]

        # Add allocator if needed
        if needs_allocator_param:
            params.append("allocator: std.mem.Allocator")

        for arg in method.args.args[1:]:  # Skip 'self'
            param_type = "i64"
            if arg.annotation and isinstance(arg.annotation, ast.Name):
                param_type = self._map_python_type_to_zig(arg.annotation.id)
            params.append(f"{arg.arg}: {param_type}")

        params_str = ", ".join(params)

        # Add error union syntax if needed
        if needs_error_union:
            return_type = f"!{return_type}"

        self.emit(f"pub fn {method.name}({params_str}) {return_type} {{")
        self.indent_level += 1

        # Generate method body
        # Track 'self' as the current instance
        old_var_types = self.var_types.copy()
        self.var_types["self"] = class_name

        for stmt in method.body:
            self.visit(stmt)

        # Restore var_types
        self.var_types = old_var_types

        self.indent_level -= 1
        self.emit("}")
        self.emit("")

    def visit_type(self, node: ast.AST, for_runtime: bool = False) -> str:
        """Convert Python type to Zig type

        Args:
            node: AST node representing the type
            for_runtime: If True, map types to runtime PyObject types
        """
        if isinstance(node, ast.Name):
            if for_runtime or self.needs_runtime:
                type_map = {
                    "int": "i64",
                    "float": "f64",
                    "bool": "bool",
                    "str": "*runtime.PyObject",
                    "list": "*runtime.PyObject",
                    "dict": "*runtime.PyObject",
                }
            else:
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

        # Handle list contains marker (for primitive ints that need wrapping)
        if test_code.startswith("__list_contains__") or test_code.startswith("!(__list_contains__"):
            is_negated = test_code.startswith("!(")
            marker = test_code[2:-1] if is_negated else test_code  # Remove !( and )
            parts = marker.split("__")
            right_code = parts[2]  # list variable
            left_code = parts[3]  # primitive int value

            # Wrap primitive int in PyInt for comparison
            temp_var = f"_list_contains_value_{id(node)}"
            self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {left_code});")
            self.emit(f"defer runtime.decref({temp_var}, allocator);")
            test_code = f"runtime.PyList.contains({right_code}, {temp_var})"
            if is_negated:
                test_code = f"!({test_code})"

        # Handle tuple contains marker (for primitive ints that need wrapping)
        elif test_code.startswith("__tuple_contains__") or test_code.startswith("!(__tuple_contains__"):
            is_negated = test_code.startswith("!(")
            marker = test_code[2:-1] if is_negated else test_code  # Remove !( and )
            parts = marker.split("__")
            right_code = parts[2]  # tuple variable
            left_code = parts[3]  # primitive int value

            # Wrap primitive int in PyInt for comparison
            temp_var = f"_tuple_contains_value_{id(node)}"
            self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {left_code});")
            self.emit(f"defer runtime.decref({temp_var}, allocator);")
            test_code = f"runtime.PyTuple.contains({right_code}, {temp_var})"
            if is_negated:
                test_code = f"!({test_code})"

        # Handle 'in' operator marker (legacy - kept for compatibility)
        elif test_code.startswith("__in_operator__"):
            parts = test_code.split("__")
            left_code = parts[2]
            left_is_pyobject = parts[3] == "True"
            right_code = parts[4]

            # Check if right side is a dict or string (based on var_types tracking)
            handled = False
            if isinstance(node.test, ast.Compare) and isinstance(node.test.comparators[0], ast.Name):
                right_var = node.test.comparators[0].id
                right_type = self.var_types.get(right_var)

                if right_type == "dict":
                    # Dict 'in' operator - check for string key
                    # Extract string value from the left side of the comparison
                    if isinstance(node.test.left, ast.Constant) and isinstance(node.test.left.value, str):
                        key_str = node.test.left.value
                        test_code = f'runtime.PyDict.contains({right_code}, "{key_str}")'
                        handled = True

                elif right_type == "string":
                    # String 'in' operator - substring search
                    # Need to create temp variable for left side (substring) if it's a creation call
                    if left_is_pyobject and left_code.startswith("runtime.PyString.create"):
                        temp_var = f"_in_substr_{id(node)}"
                        self.emit(f"const {temp_var} = try {left_code};")
                        self.emit(f"defer runtime.decref({temp_var}, allocator);")
                        test_code = f"runtime.PyString.contains({right_code}, {temp_var})"
                    else:
                        test_code = f"runtime.PyString.contains({right_code}, {left_code})"
                    handled = True

            # List 'in' operator - need to wrap primitive in PyInt
            if not handled:
                if not left_is_pyobject:
                    temp_var = f"_in_check_value_{id(node)}"
                    self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {left_code});")
                    self.emit(f"defer runtime.decref({temp_var}, allocator);")
                    test_code = f"runtime.PyList.contains({right_code}, {temp_var})"
                else:
                    test_code = f"runtime.PyList.contains({right_code}, {left_code})"

        # Handle inline PyString.create in method calls like startswith/endswith
        # Extract them into temp variables to avoid memory leaks
        import re
        create_pattern = r'try runtime\.PyString\.create\(allocator, "([^"]*)"\)'
        if re.search(create_pattern, test_code):
            matches = list(re.finditer(create_pattern, test_code))
            for i, match in enumerate(matches):
                temp_var = f"_if_temp_str_{id(node)}_{i}"
                self.emit(f'const {temp_var} = try runtime.PyString.create(allocator, "{match.group(1)}");')
                self.emit(f"defer runtime.decref({temp_var}, allocator);")
                test_code = test_code.replace(match.group(0), temp_var)

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
                    step = "1"
                elif len(args) == 2:
                    # range(start, end)
                    start_code, _ = self.visit_expr(args[0])
                    end_code, _ = self.visit_expr(args[1])
                    start = start_code
                    step = "1"
                elif len(args) == 3:
                    # range(start, end, step)
                    start_code, _ = self.visit_expr(args[0])
                    end_code, _ = self.visit_expr(args[1])
                    step_code, _ = self.visit_expr(args[2])
                    start = start_code
                    step = step_code
                else:
                    raise NotImplementedError("range() requires 1-3 arguments")

                # Get loop variable
                if isinstance(node.target, ast.Name):
                    loop_var = node.target.id
                else:
                    raise NotImplementedError("Complex loop targets not supported")

                # Track loop variable type
                self.var_types[loop_var] = "int"

                # Generate while loop equivalent
                # Check if loop variable already declared (reused in multiple loops)
                if loop_var in self.declared_vars:
                    # Already declared, just assign
                    self.emit(f"{loop_var} = {start};")
                else:
                    # First declaration
                    self.emit(f"var {loop_var}: i64 = {start};")
                    self.declared_vars.add(loop_var)
                self.emit(f"while ({loop_var} < {end_code}) {{")
                self.indent_level += 1

                for stmt in node.body:
                    self.visit(stmt)

                # Increment loop variable by step
                self.emit(f"{loop_var} += {step};")

                self.indent_level -= 1
                self.emit("}")
            elif node.iter.func.id == "enumerate":
                # enumerate(iterable) - iterate with index
                # Target must be a tuple: (index_var, value_var)
                if not isinstance(node.target, ast.Tuple) or len(node.target.elts) != 2:
                    raise NotImplementedError("enumerate() requires tuple unpacking: for i, val in enumerate(...)")

                if not isinstance(node.target.elts[0], ast.Name) or not isinstance(node.target.elts[1], ast.Name):
                    raise NotImplementedError("enumerate() target variables must be simple names")

                index_var = node.target.elts[0].id
                value_var = node.target.elts[1].id

                # Get the iterable
                iterable_code, _ = self.visit_expr(node.iter.args[0])

                # Track variable types
                self.var_types[index_var] = "int"
                # Determine value type from iterable
                if isinstance(node.iter.args[0], ast.Name):
                    iterable_name = node.iter.args[0].id
                    list_elem_type = self.list_element_types.get(iterable_name, "string")
                    if list_elem_type == "int":
                        self.var_types[value_var] = "pyint"
                    else:
                        self.var_types[value_var] = "string"

                # Generate while loop with index
                if index_var in self.declared_vars:
                    self.emit(f"{index_var} = 0;")
                else:
                    self.emit(f"var {index_var}: i64 = 0;")
                    self.declared_vars.add(index_var)

                self.emit(f"while ({index_var} < runtime.PyList.len({iterable_code})) {{")
                self.indent_level += 1

                # Get list item (cast i64 to usize)
                # Note: getItem() returns borrowed reference, don't decref
                self.emit(f"const {value_var} = try runtime.PyList.getItem({iterable_code}, @intCast({index_var}));")
                self.declared_vars.add(value_var)

                # Execute loop body
                for stmt in node.body:
                    self.visit(stmt)

                # Increment index
                self.emit(f"{index_var} += 1;")

                self.indent_level -= 1
                self.emit("}")
            elif node.iter.func.id == "zip":
                # zip(iterables...) - parallel iteration
                # Target must be a tuple with same number of elements as zip arguments
                if not isinstance(node.target, ast.Tuple):
                    raise NotImplementedError("zip() requires tuple unpacking: for a, b in zip(...)")

                if len(node.target.elts) != len(node.iter.args):
                    raise NotImplementedError(f"zip() target must have {len(node.iter.args)} variables")

                # Get all target variables
                target_vars = []
                for elt in node.target.elts:
                    if not isinstance(elt, ast.Name):
                        raise NotImplementedError("zip() target variables must be simple names")
                    target_vars.append(elt.id)

                # Get all iterables
                iterable_codes: list[str] = []
                iterable_names: list[str | None] = []
                for arg in node.iter.args:
                    code, _ = self.visit_expr(arg)
                    iterable_codes.append(code)
                    if isinstance(arg, ast.Name):
                        iterable_names.append(arg.id)
                    else:
                        iterable_names.append(None)

                # Create index variable
                index_var = f"_zip_idx_{id(node)}"
                self.emit(f"var {index_var}: i64 = 0;")

                # Find minimum length across all iterables
                min_len_var = f"_zip_min_len_{id(node)}"
                len_exprs = [f"runtime.PyList.len({code})" for code in iterable_codes]
                if len(len_exprs) == 2:
                    self.emit(f"const {min_len_var} = @min({len_exprs[0]}, {len_exprs[1]});")
                else:
                    # For 3+ lists, chain @min calls
                    min_expr = f"@min({len_exprs[0]}, {len_exprs[1]})"
                    for i in range(2, len(len_exprs)):
                        min_expr = f"@min({min_expr}, {len_exprs[i]})"
                    self.emit(f"const {min_len_var} = {min_expr};")

                # Generate while loop
                self.emit(f"while ({index_var} < {min_len_var}) {{")
                self.indent_level += 1

                # Get items from each list
                for i, (target_var, iterable_code, iterable_name) in enumerate(zip(target_vars, iterable_codes, iterable_names)):  # type: ignore[assignment]
                    self.emit(f"const {target_var} = try runtime.PyList.getItem({iterable_code}, @intCast({index_var}));")
                    self.declared_vars.add(target_var)

                    # Track variable type
                    if iterable_name is not None:
                        elem_type = self.list_element_types.get(iterable_name, "string")
                        if elem_type == "int":
                            self.var_types[target_var] = "pyint"
                        else:
                            self.var_types[target_var] = "string"

                # Execute loop body
                for stmt in node.body:
                    self.visit(stmt)

                # Increment index
                self.emit(f"{index_var} += 1;")

                self.indent_level -= 1
                self.emit("}")
            else:
                raise NotImplementedError(f"for loop over {node.iter.func.id}() not supported")
        else:
            raise NotImplementedError("for loop only supports range() for now")

    def visit_Return(self, node: ast.Return) -> None:
        """Generate return statement"""
        if node.value:
            # Special handling for string concatenation with inline constants
            if isinstance(node.value, ast.BinOp) and isinstance(node.value.op, ast.Add):
                # Check if either operand is a string constant
                temp_vars = []
                if isinstance(node.value.left, ast.Constant) and isinstance(node.value.left.value, str):
                    temp_var = f"_temp_ret_{id(node.value.left)}"
                    self.emit(f"const {temp_var} = try runtime.PyString.create(allocator, \"{node.value.left.value}\");")
                    self.emit(f"defer runtime.decref({temp_var}, allocator);")
                    temp_vars.append(('left', temp_var))
                if isinstance(node.value.right, ast.Constant) and isinstance(node.value.right.value, str):
                    temp_var = f"_temp_ret_{id(node.value.right)}"
                    self.emit(f"const {temp_var} = try runtime.PyString.create(allocator, \"{node.value.right.value}\");")
                    self.emit(f"defer runtime.decref({temp_var}, allocator);")
                    temp_vars.append(('right', temp_var))

                if temp_vars:
                    # Build concat with temp vars
                    left_code, _ = self.visit_expr(node.value.left) if 'left' not in [v[0] for v in temp_vars] else (temp_vars[0][1], False)
                    right_code, _ = self.visit_expr(node.value.right) if 'right' not in [v[0] for v in temp_vars] else (temp_vars[1][1] if len(temp_vars) > 1 else temp_vars[0][1], False)

                    # Replace with actual temp var if we created one
                    for side, var in temp_vars:
                        if side == 'left':
                            left_code = var
                        else:
                            right_code = var

                    self.emit(f"return try runtime.PyString.concat(allocator, {left_code}, {right_code});")
                    return

            value_code, value_try = self.visit_expr(node.value)
            if value_try:
                self.emit(f"return try {value_code};")
            else:
                self.emit(f"return {value_code};")
        else:
            self.emit("return;")

    def visit_Assert(self, node: ast.Assert) -> None:
        """Generate assert statement"""
        # Generate condition check
        test_code, test_try = self.visit_expr(node.test)

        # Handle list contains marker (for primitive ints that need wrapping)
        if test_code.startswith("__list_contains__") or test_code.startswith("!(__list_contains__"):
            is_negated = test_code.startswith("!(")
            marker = test_code[2:-1] if is_negated else test_code  # Remove !( and )
            parts = marker.split("__")
            right_code = parts[2]  # list variable
            left_code = parts[3]  # primitive int value

            # Wrap primitive int in PyInt for comparison
            temp_var = f"_list_contains_value_{id(node)}"
            self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {left_code});")
            self.emit(f"defer runtime.decref({temp_var}, allocator);")
            test_code = f"runtime.PyList.contains({right_code}, {temp_var})"
            if is_negated:
                test_code = f"!({test_code})"

        # Build assertion message
        if node.msg:
            # Custom message provided
            msg_code, _ = self.visit_expr(node.msg)
            # Check if message is a string literal or PyString
            if isinstance(node.msg, ast.Constant) and isinstance(node.msg.value, str):
                msg_str = node.msg.value
            else:
                # For non-literal messages, create a temp var to get the value
                temp_msg_var = f"_assert_msg_{id(node)}"
                self.emit(f"const {temp_msg_var} = {msg_code};")
                self.emit(f"if (!({test_code})) {{")
                self.indent_level += 1
                self.emit(f'_ = std.debug.print("AssertionError: {{s}}\\n", .{{runtime.PyString.getValue({temp_msg_var})}});')
                self.emit(f"defer runtime.decref({temp_msg_var}, allocator);")
                self.emit("std.process.exit(1);")
                self.indent_level -= 1
                self.emit("}")
                return

            # String literal message
            self.emit(f"if (!({test_code})) {{")
            self.indent_level += 1
            self.emit(f'_ = std.debug.print("AssertionError: {msg_str}\\n", .{{}});')
            self.emit("std.process.exit(1);")
            self.indent_level -= 1
            self.emit("}")
        else:
            # No custom message - use default
            self.emit(f"if (!({test_code})) {{")
            self.indent_level += 1
            self.emit('_ = std.debug.print("AssertionError\\n", .{});')
            self.emit("std.process.exit(1);")
            self.indent_level -= 1
            self.emit("}")

    def visit_Try(self, node: ast.Try) -> None:
        """Generate try/except block with proper error handling"""
        if not node.handlers:
            # No except blocks - just emit the try body
            for stmt in node.body:
                self.visit(stmt)
            return

        # Parse exception handlers
        handlers_info: list[tuple[str | None, list[ast.stmt], str | None]] = []
        for handler in node.handlers:
            if handler.type is None:
                # Bare except: catches all errors
                handlers_info.append((None, handler.body, handler.name))
            elif isinstance(handler.type, ast.Name):
                # Specific exception type
                exc_type = handler.type.id
                handlers_info.append((exc_type, handler.body, handler.name))
            else:
                raise NotImplementedError("Complex exception types not supported")

        # Generate unique label for this try block
        block_label = f"try_catch_{id(node)}"

        # Save current try context
        prev_in_try = getattr(self, '_in_try_block', False)
        prev_handlers = getattr(self, '_current_handlers', [])
        prev_label: str | None = getattr(self, '_try_block_label', None)

        # Set new try context
        self._in_try_block = True
        self._current_handlers = handlers_info
        self._try_block_label: str | None = block_label

        # Emit labeled block
        self.emit(f"{block_label}: {{")
        self.indent_level += 1

        # Emit try block body
        for stmt in node.body:
            self.visit(stmt)

        self.indent_level -= 1
        self.emit("}")

        # Restore previous context
        self._in_try_block = prev_in_try
        self._current_handlers = prev_handlers
        self._try_block_label = prev_label

    def _emit_error_handler_for_stmt(self, stmt_with_try: str, var_name: str = "_") -> None:
        """Emit a statement that may error with inline error handling if in try block"""
        if not getattr(self, '_in_try_block', False):
            # Not in try block - use regular try
            self.emit(f"{stmt_with_try};")
            return

        # In try block - use inline catch with error type checking
        handlers = getattr(self, '_current_handlers', [])
        label = getattr(self, '_try_block_label', 'try_catch')

        # Check if we need to capture the error (only if there are specific exception types)
        has_specific_handlers = any(exc_type is not None for exc_type, _, _ in handlers)

        # Emit statement with catch handler
        if has_specific_handlers:
            self.emit(f"{var_name} = {stmt_with_try} catch |err| {{")
        else:
            # Bare except only - no need to capture error
            self.emit(f"{var_name} = {stmt_with_try} catch {{")
        self.indent_level += 1

        # Generate if-else chain for exception type matching
        for i, (exc_type, handler_body, exc_var_name) in enumerate(handlers):
            if exc_type is None:
                # Bare except - catches everything
                if i > 0:
                    self.emit("else {")
                    self.indent_level += 1

                for stmt in handler_body:
                    self.visit(stmt)

                self.emit(f"break :{label};")

                if i > 0:
                    self.indent_level -= 1
                    self.emit("}")
            else:
                # Specific exception type
                if i == 0:
                    self.emit(f"if (err == error.{exc_type}) {{")
                else:
                    self.emit(f"}} else if (err == error.{exc_type}) {{")

                self.indent_level += 1

                for stmt in handler_body:
                    self.visit(stmt)

                self.emit(f"break :{label};")

                self.indent_level -= 1

        # If no handler matched and there's no bare except, return the error (propagate up)
        has_bare_except = any(exc_type is None for exc_type, _, _ in handlers)
        if handlers and not has_bare_except and any(exc_type is not None for exc_type, _, _ in handlers):
            # Close the if-else chain and add fallback
            self.emit("} else {")
            self.indent_level += 1
            self.emit("return err;")
            self.indent_level -= 1
            self.emit("}")
        elif handlers and not has_bare_except:
            # No specific handlers, but handlers exist (shouldn't happen)
            pass

        self.indent_level -= 1
        self.emit("};")

    def _flatten_binop_chain(self, node: ast.BinOp, op_type: type) -> list[ast.AST]:
        """Flatten chained binary operations like a + b + c into [a, b, c]"""
        result = []
        if isinstance(node.left, ast.BinOp) and isinstance(node.left.op, op_type):
            result.extend(self._flatten_binop_chain(node.left, op_type))
        else:
            result.append(node.left)
        result.append(node.right)
        return result

    def _unwrap_primitive_markers(self, expr_code: str, context_id: int) -> str:
        """Unwrap __WRAP_PRIMITIVE__ markers by creating temp variables."""
        if "__WRAP_PRIMITIVE__" not in expr_code:
            return expr_code

        import re
        marker_pattern = r'__WRAP_PRIMITIVE__([^,\)]+)'
        matches = re.findall(marker_pattern, expr_code)

        if not matches:
            return expr_code

        replacements = []
        for i, prim_val in enumerate(matches):
            temp_var = f"_wrapped_{context_id}_{i}"
            self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {prim_val});")
            self.emit(f"defer runtime.decref({temp_var}, allocator);")
            replacements.append((f"__WRAP_PRIMITIVE__{prim_val}", temp_var))

        for marker, temp_var in replacements:
            expr_code = expr_code.replace(marker, temp_var)

        return expr_code

    def _expand_sum_markers(self, expr_code: str) -> str:
        """Expand __sum_call__ markers by generating loop code."""
        if "__sum_call_" not in expr_code:
            return expr_code

        import re
        marker_pattern = r'__sum_call_(\d+)__([a-zA-Z_][a-zA-Z0-9_]*)'
        matches = re.findall(marker_pattern, expr_code)

        if not matches:
            return expr_code

        replacements = []
        for call_id, list_code in matches:
            # Generate unique variable names for this sum operation
            result_var = f"_sum_result_{call_id}"
            idx_var = f"_sum_idx_{call_id}"

            # Generate the sum loop code
            self.emit(f"var {result_var}: i64 = 0;")
            self.emit(f"var {idx_var}: i64 = 0;")
            self.emit(f"while ({idx_var} < runtime.PyList.len({list_code})) : ({idx_var} += 1) {{")
            self.indent_level += 1
            self.emit(f"const _sum_item_{call_id} = try runtime.PyList.getItem({list_code}, @intCast({idx_var}));")
            self.emit(f"{result_var} += runtime.PyInt.getValue(_sum_item_{call_id});")
            self.indent_level -= 1
            self.emit("}")

            # Replace the marker with the result variable
            replacements.append((f"__sum_call_{call_id}__{list_code}", result_var))

        for marker, result_var in replacements:
            expr_code = expr_code.replace(marker, result_var)

        return expr_code

    def visit_Assign(self, node: ast.Assign) -> None:
        """Generate variable assignment"""
        # For now, assume single target
        target = node.targets[0]

        # Handle attribute assignment (e.g., self.value = ...)
        if isinstance(target, ast.Attribute):
            # This is an attribute assignment like self.field = value
            obj_code, _ = self.visit_expr(target.value)
            attr_name = target.attr
            value_code, value_try = self.visit_expr(node.value)

            if value_try:
                self.emit(f"{obj_code}.{attr_name} = try {value_code};")
            else:
                self.emit(f"{obj_code}.{attr_name} = {value_code};")
            return

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
                            # Decref old value before reassignment
                            self.emit(f"runtime.decref({target.id}, allocator);")
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
                            # Decref old value before reassignment
                            self.emit(f"runtime.decref({target.id}, allocator);")
                            self.emit(f"{target.id} = {result_var};")

                    if is_first_assignment:
                        self.emit(f"defer runtime.decref({target.id}, allocator);")
                    self.var_types[target.id] = "string"
                    return

            # Special handling for list literals
            if isinstance(node.value, ast.List):
                # Track this as a list type
                self.var_types[target.id] = "list"

                # Detect element type from first element
                if node.value.elts:
                    first_elem = node.value.elts[0]
                    if isinstance(first_elem, ast.Constant):
                        if isinstance(first_elem.value, str):
                            self.list_element_types[target.id] = "string"
                        elif isinstance(first_elem.value, int):
                            self.list_element_types[target.id] = "int"

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

            # Special handling for tuple literals
            if isinstance(node.value, ast.Tuple):
                # Track this as a tuple type
                self.var_types[target.id] = "tuple"

                # Detect element type (check if all elements are same type)
                if node.value.elts:
                    # Check if all elements are the same type
                    all_same_type = True
                    elem_type = None
                    for elem in node.value.elts:
                        if isinstance(elem, ast.Constant):
                            if elem_type is None:
                                if isinstance(elem.value, str):
                                    elem_type = "string"
                                elif isinstance(elem.value, int):
                                    elem_type = "int"
                            else:
                                current_type = None
                                if isinstance(elem.value, str):
                                    current_type = "string"
                                elif isinstance(elem.value, int):
                                    current_type = "int"
                                if current_type != elem_type:
                                    all_same_type = False
                                    break
                    # Only track if all elements are the same type
                    if all_same_type and elem_type:
                        self.tuple_element_types[target.id] = elem_type

                # Create tuple with fixed size
                tuple_size = len(node.value.elts)
                if is_first_assignment:
                    self.emit(f"{var_keyword} {target.id} = try runtime.PyTuple.create(allocator, {tuple_size});")
                    self.emit(f"defer runtime.decref({target.id}, allocator);")
                else:
                    self.emit(f"{target.id} = try runtime.PyTuple.create(allocator, {tuple_size});")

                # Set each element
                for idx, elem in enumerate(node.value.elts):
                    elem_code, elem_try = self.visit_expr(elem)
                    if elem_try:
                        # PyObject - need to create it first
                        temp_var = f"_temp_elem_{id(elem)}"
                        self.emit(f"const {temp_var} = try {elem_code};")
                        self.emit(f"runtime.PyTuple.setItem({target.id}, {idx}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")
                    else:
                        # Primitive value - wrap in PyInt
                        temp_var = f"_temp_elem_{id(elem)}"
                        self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {elem_code});")
                        self.emit(f"runtime.PyTuple.setItem({target.id}, {idx}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")
                return

            # Special handling for list comprehensions
            if isinstance(node.value, ast.ListComp):
                # Track this as a list type
                self.var_types[target.id] = "list"

                # Create empty list
                if is_first_assignment:
                    self.emit(f"{var_keyword} {target.id} = try runtime.PyList.create(allocator);")
                    self.emit(f"defer runtime.decref({target.id}, allocator);")
                else:
                    self.emit(f"{target.id} = try runtime.PyList.create(allocator);")

                # Generate for loop for comprehension
                comp = node.value.generators[0]  # For now, handle single generator

                # Extract loop variable name
                if not isinstance(comp.target, ast.Name):
                    raise NotImplementedError("List comprehension only supports simple loop variables for now")
                loop_var = comp.target.id

                iter_code, iter_try = self.visit_expr(comp.iter)

                # Check if iterating over a list variable
                if isinstance(comp.iter, ast.Name):
                    source_var = comp.iter.id
                    # Generate unique index variable name for this comprehension
                    unique_idx = f"{loop_var}_idx_{id(node.value)}"
                    # Generate for loop using range(len(source))
                    self.emit(f"var {unique_idx}: i64 = 0;")
                    self.emit(f"while ({unique_idx} < @as(i64, @intCast(runtime.PyList.len({source_var})))) : ({unique_idx} += 1) {{")
                    self.indent_level += 1

                    # Get item from source list (getItem can throw IndexError)
                    self.emit(f"const {loop_var} = try runtime.PyList.getItem({source_var}, @intCast({unique_idx}));")

                    # Track loop variable as pyint (PyObject containing int)
                    self.var_types[loop_var] = "pyint"

                    # Check for filter conditions
                    if comp.ifs:
                        # Generate if statement for filter
                        for filter_expr in comp.ifs:
                            filter_code, filter_try = self.visit_expr(filter_expr)
                            self.emit(f"if ({filter_code}) {{")
                            self.indent_level += 1

                    # Evaluate the element expression and append
                    elem_code, elem_try = self.visit_expr(node.value.elt)

                    # Check if the element is just the loop variable itself
                    if elem_code == loop_var:
                        # Loop variable from list is already a PyObject, append directly
                        self.emit(f"try runtime.PyList.append({target.id}, {elem_code});")
                    elif elem_try:
                        # PyObject result
                        temp_var = f"_comp_elem_{id(node.value)}"
                        self.emit(f"const {temp_var} = try {elem_code};")
                        self.emit(f"try runtime.PyList.append({target.id}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")
                    else:
                        # Primitive result - wrap in PyInt
                        temp_var = f"_comp_elem_{id(node.value)}"
                        self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {elem_code});")
                        self.emit(f"try runtime.PyList.append({target.id}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")

                    # Close filter if statements
                    if comp.ifs:
                        for _ in comp.ifs:
                            self.indent_level -= 1
                            self.emit("}")

                    self.indent_level -= 1
                    self.emit("}")
                else:
                    raise NotImplementedError("List comprehension only supports iterating over list variables for now")
                return

            # Special handling for subscript assignment (infer type from list element type)
            if isinstance(node.value, ast.Subscript):
                # Check if it's a slice operation - if so, don't set type here
                # The slice type tracking below (line ~1706) will handle it correctly
                if not isinstance(node.value.slice, ast.Slice):
                    # Single-item subscripting - infer type from list element type
                    if isinstance(node.value.value, ast.Name):
                        list_var = node.value.value.id
                        elem_type = self.list_element_types.get(list_var)
                        if elem_type == "string":
                            self.var_types[target.id] = "string"
                        else:
                            # Default to pyint for lists with unknown or int elements
                            self.var_types[target.id] = "pyint"
                    else:
                        # Unknown subscript source, default to pyint
                        self.var_types[target.id] = "pyint"

            # Special handling for list.pop() and dict.pop() (returns PyObject, type unknown until runtime)
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute):
                if node.value.func.attr == "pop":
                    self.var_types[target.id] = "pyobject"

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

            # Special handling for binary ops with PyObjects (e.g., total + list[i] or total + list.pop())
            if isinstance(node.value, ast.BinOp) and isinstance(node.value.op, ast.Add):
                left_code, left_try = self.visit_expr(node.value.left)
                right_code, right_try = self.visit_expr(node.value.right)

                # If either side is a subscript (returns PyObject), extract the value
                left_expr = left_code
                if isinstance(node.value.left, ast.Subscript):
                    left_expr = f"runtime.PyInt.getValue(try {left_code})"

                right_expr = right_code
                if isinstance(node.value.right, ast.Subscript):
                    right_expr = f"runtime.PyInt.getValue(try {right_code})"
                # Also check if right side is a method call that returns PyObject (like pop())
                elif isinstance(node.value.right, ast.Call) and isinstance(node.value.right.func, ast.Attribute):
                    method_name = node.value.right.func.attr
                    if method_name == "pop":
                        right_expr = f"runtime.PyInt.getValue(try {right_code})"

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

            # Track type for simple string constants
            if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                self.var_types[target.id] = "string"

            # Track type for slicing results
            if isinstance(node.value, ast.Subscript) and isinstance(node.value.slice, ast.Slice):
                # If slicing a variable, copy its type
                if isinstance(node.value.value, ast.Name):
                    source_type = self.var_types.get(node.value.value.id)
                    # Always set type - default to list if source type unknown
                    self.var_types[target.id] = source_type if source_type else "list"

            # Track type for class instantiation
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name):
                func_name = node.value.func.id
                # Check if it's a class constructor
                if func_name in self.class_definitions:
                    self.var_types[target.id] = func_name  # Track as class instance

            # Track type for user-defined function calls
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name):
                func_name = node.value.func.id
                if func_name in self.function_signatures:
                    sig = self.function_signatures[func_name]
                    if sig["returns_pyobject"]:
                        self.var_types[target.id] = "string"  # Default to string for PyObjects
                    else:
                        self.var_types[target.id] = "int"  # Default to int for primitives

            # Special handling for module function calls with string arguments (e.g., strutils.repeat("Hi", 5))
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute):
                if isinstance(node.value.func.value, ast.Name):
                    module_name = node.value.func.value.id
                    func_name = node.value.func.attr
                    if module_name in self.module_functions:
                        if func_name in self.module_functions[module_name]:
                            sig = self.module_functions[module_name][func_name]

                            # Check if any arguments are string constants
                            temp_args = []
                            for i, arg in enumerate(node.value.args):
                                if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                                    temp_var = f"_temp_arg_{id(arg)}"
                                    self.emit(f"const {temp_var} = try runtime.PyString.create(allocator, \"{arg.value}\");")
                                    self.emit(f"defer runtime.decref({temp_var}, allocator);")
                                    temp_args.append((i, temp_var))

                            # If we have temp args, generate the call with them
                            if temp_args:
                                args = []
                                if sig["needs_allocator"]:
                                    args.append("allocator")

                                temp_arg_dict = dict(temp_args)
                                for i, arg in enumerate(node.value.args):
                                    if i in temp_arg_dict:
                                        args.append(temp_arg_dict[i])
                                    else:
                                        arg_code, arg_try = self.visit_expr(arg)
                                        if arg_try:
                                            args.append(f"try {arg_code}")
                                        else:
                                            args.append(arg_code)

                                func_call = f"{module_name}_{func_name}({', '.join(args)})"
                                needs_try = sig.get("returns_pyobject", False) or sig.get("return_type", "").startswith("!")

                                # Track type
                                if sig["returns_pyobject"]:
                                    self.var_types[target.id] = "string"  # Default to string for PyObjects
                                else:
                                    self.var_types[target.id] = "int"  # Default to int for primitives

                                if is_first_assignment:
                                    if needs_try:
                                        self.emit(f"{var_keyword} {target.id} = try {func_call};")
                                        if sig.get("returns_pyobject", False):
                                            self.emit(f"defer runtime.decref({target.id}, allocator);")
                                    else:
                                        self.emit(f"{var_keyword} {target.id} = {func_call};")
                                else:
                                    # Reassignment
                                    var_type = self.var_types.get(target.id)
                                    is_pyobject = var_type in ["string", "list", "dict", "pyint"]
                                    if is_pyobject:
                                        self.emit(f"runtime.decref({target.id}, allocator);")
                                    if needs_try:
                                        self.emit(f"{target.id} = try {func_call};")
                                    else:
                                        self.emit(f"{target.id} = {func_call};")
                                return

                            # No temp args - just track type
                            if sig["returns_pyobject"]:
                                self.var_types[target.id] = "string"  # Default to string for PyObjects
                            else:
                                self.var_types[target.id] = "int"  # Default to int for primitives

            # Track type when assigning from another variable
            if isinstance(node.value, ast.Name):
                source_type = self.var_types.get(node.value.id)
                if source_type:
                    self.var_types[target.id] = source_type

            # Track type for method calls that return primitives
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute):
                method_name = node.value.func.attr
                from core.method_registry import get_method_info, ReturnType

                # Get object type for disambiguation
                obj_type = None
                if isinstance(node.value.func.value, ast.Name):
                    obj_type = self.var_types.get(node.value.func.value.id)

                method_info = get_method_info(method_name, obj_type)
                if method_info and method_info.return_type == ReturnType.PRIMITIVE_INT:
                    self.var_types[target.id] = "int"

                # Track element types for methods that return lists
                if method_info and method_info.return_type == ReturnType.PYOBJECT:
                    if method_name == "split":
                        # split() returns a list of strings
                        self.var_types[target.id] = "list"
                        self.list_element_types[target.id] = "string"
                    elif method_name in ("keys", "values", "items"):
                        # dict.keys(), dict.values(), dict.items() all return lists
                        self.var_types[target.id] = "list"
                    elif method_name == "pop":
                        # pop() returns PyObject with unknown type until runtime
                        self.var_types[target.id] = "pyobject"
                    elif method_name == "copy":
                        # copy() returns same type as source
                        if obj_type == "dict":
                            self.var_types[target.id] = "dict"
                        elif obj_type == "list":
                            self.var_types[target.id] = "list"
                    else:
                        # Default: method returns same type as the object it's called on
                        # (e.g., text.upper() returns string, numbers.copy() returns list)
                        if obj_type:
                            self.var_types[target.id] = obj_type

                # Track types for methods that return PyObject directly (no error union)
                if method_info and method_info.return_type == ReturnType.PYOBJECT_DIRECT:
                    if method_name == "get":
                        # dict.get() returns PyInt (assume int values for now)
                        self.var_types[target.id] = "pyint"
                    elif method_name == "copy":
                        # copy() returns same type as source
                        if obj_type == "dict":
                            self.var_types[target.id] = "dict"
                        elif obj_type == "list":
                            self.var_types[target.id] = "list"
                    else:
                        # Default: method returns same type as the object it's called on
                        # (e.g., text.upper() returns string, numbers.copy() returns list)
                        if obj_type:
                            self.var_types[target.id] = obj_type

            # Special handling for method calls with string arguments that need cleanup
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute):
                method_name = node.value.func.attr

                # Check if any arguments are string constants (will create temporary PyStrings)
                temp_args = []
                for i, arg in enumerate(node.value.args):
                    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                        # This will create a temporary PyString that needs to be freed
                        temp_var = f"_temp_arg_{id(arg)}"
                        self.emit(f"const {temp_var} = try runtime.PyString.create(allocator, \"{arg.value}\");")
                        self.emit(f"defer runtime.decref({temp_var}, allocator);")
                        temp_args.append((i, temp_var))

                # If we have temp args, generate the method call with them
                if temp_args:
                    obj_code, obj_try = self.visit_expr(node.value.func.value)

                    from core.method_registry import get_method_info, ReturnType
                    obj_type = None
                    if isinstance(node.value.func.value, ast.Name):
                        obj_type = self.var_types.get(node.value.func.value.id)

                    method_info = get_method_info(method_name, obj_type)

                    if method_info:
                        args = []
                        if method_info.needs_allocator:
                            args.append("allocator")
                        args.append(obj_code)

                        # Add arguments, using temp vars where we created them
                        temp_arg_dict = dict(temp_args)
                        for i, arg in enumerate(node.value.args):
                            if i in temp_arg_dict:
                                args.append(temp_arg_dict[i])
                            else:
                                arg_code, arg_try = self.visit_expr(arg)
                                if arg_try:
                                    args.append(f"try {arg_code}")
                                else:
                                    # Wrap primitives in PyInt if method requires it (e.g., dict.get default param)
                                    if hasattr(method_info, 'wrap_primitive_args') and method_info.wrap_primitive_args:
                                        # Create temp PyInt for primitive argument
                                        temp_prim_var = f"_temp_prim_{id(arg)}_{i}"
                                        self.emit(f"const {temp_prim_var} = try runtime.PyInt.create(allocator, {arg_code});")
                                        self.emit(f"defer runtime.decref({temp_prim_var}, allocator);")
                                        # Method borrows this (may or may not return it)
                                        args.append(temp_prim_var)
                                    else:
                                        args.append(arg_code)

                        runtime_call = f"runtime.{method_info.runtime_type}.{method_info.runtime_fn}({', '.join(args)})"

                        # Generate assignment
                        if is_first_assignment:
                            if method_info.return_type == ReturnType.PYOBJECT:
                                self.emit(f"{var_keyword} {target.id} = try {runtime_call};")
                                self.emit(f"defer runtime.decref({target.id}, allocator);")
                            elif method_info.return_type == ReturnType.PYOBJECT_DIRECT:
                                # PYOBJECT_DIRECT methods like dict.get() return owned references
                                self.emit(f"{var_keyword} {target.id} = {runtime_call};")
                                # dict.get() returns owned reference that needs decref
                                if method_name == "get":
                                    self.emit(f"defer runtime.decref({target.id}, allocator);")
                            else:
                                self.emit(f"{var_keyword} {target.id} = {runtime_call};")
                        else:
                            # Reassignment
                            var_type = self.var_types.get(target.id)
                            is_pyobject = var_type in ["string", "list", "dict", "pyint"]
                            if is_pyobject:
                                self.emit(f"runtime.decref({target.id}, allocator);")
                            if method_info.return_type == ReturnType.PYOBJECT:
                                self.emit(f"{target.id} = try {runtime_call};")
                            else:
                                self.emit(f"{target.id} = {runtime_call};")
                        return

            # Special handling for user-defined function calls with string arguments
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name):
                func_name = node.value.func.id
                if func_name in self.function_signatures:
                    # Check if any arguments are string constants
                    temp_args = []
                    for i, arg in enumerate(node.value.args):
                        if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                            temp_var = f"_temp_arg_{id(arg)}"
                            self.emit(f"const {temp_var} = try runtime.PyString.create(allocator, \"{arg.value}\");")
                            self.emit(f"defer runtime.decref({temp_var}, allocator);")
                            temp_args.append((i, temp_var))

                    if temp_args:
                        # Build function call with temp vars
                        sig = self.function_signatures[func_name]
                        args = []
                        if sig["needs_allocator"]:
                            args.append("allocator")

                        temp_arg_dict = dict(temp_args)
                        for i, arg in enumerate(node.value.args):
                            if i in temp_arg_dict:
                                args.append(temp_arg_dict[i])
                            else:
                                arg_code, arg_try = self.visit_expr(arg)
                                if arg_try:
                                    args.append(f"try {arg_code}")
                                else:
                                    args.append(arg_code)

                        return_type = sig.get("return_type", "")
                        needs_try = sig.get("returns_pyobject", False) or (isinstance(return_type, str) and return_type.startswith("!"))
                        func_call = f"{func_name}({', '.join(args)})"

                        if is_first_assignment:
                            if needs_try:
                                self.emit(f"{var_keyword} {target.id} = try {func_call};")
                                # Check if return is PyObject that needs decref
                                if sig.get("returns_pyobject", False):
                                    self.emit(f"defer runtime.decref({target.id}, allocator);")
                                    # Track return type for print handling
                                    if return_type == "*runtime.PyObject":
                                        self.var_types[target.id] = "pyobject"  # Runtime type check needed
                            else:
                                self.emit(f"{var_keyword} {target.id} = {func_call};")
                        else:
                            # Reassignment
                            var_type = self.var_types.get(target.id)
                            is_pyobject = var_type in ["string", "list", "dict", "pyint"]
                            if is_pyobject:
                                self.emit(f"runtime.decref({target.id}, allocator);")
                            if needs_try:
                                self.emit(f"{target.id} = try {func_call};")
                            else:
                                self.emit(f"{target.id} = {func_call};")
                        return

            # Default path
            value_code, needs_try = self.visit_expr(node.value)

            # Unwrap any __WRAP_PRIMITIVE__ markers
            value_code = self._unwrap_primitive_markers(value_code, id(node))

            # Track type for simple constant assignments
            if isinstance(node.value, ast.Constant):
                if isinstance(node.value.value, int) and not isinstance(node.value.value, bool):
                    self.var_types[target.id] = "int"
                elif isinstance(node.value.value, str):
                    self.var_types[target.id] = "string"
                elif isinstance(node.value.value, bool):
                    # bool is a subclass of int in Python, so check it first
                    pass  # Don't track bool separately for now

            # Track type for built-in function calls that return lists
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name):
                func_name = node.value.func.id
                if func_name == "range":
                    self.var_types[target.id] = "list"
                    self.list_element_types[target.id] = "int"
                elif func_name in ["enumerate", "zip"]:
                    self.var_types[target.id] = "list"
                    self.list_element_types[target.id] = "tuple"
                elif func_name in ["sorted", "reversed", "filter"]:
                    self.var_types[target.id] = "list"
                    # Element type preserved from input, but we don't track it here for simplicity

            # Track type for subscript access from lists with known element types
            if isinstance(node.value, ast.Subscript):
                if isinstance(node.value.value, ast.Name):
                    source_var = node.value.value.id
                    source_type = self.var_types.get(source_var)
                    # If subscripting a list, check if we know what type of elements it contains
                    if source_type == "list":
                        elem_type = self.list_element_types.get(source_var)
                        if elem_type == "tuple":
                            self.var_types[target.id] = "tuple"
                        elif elem_type == "int":
                            self.var_types[target.id] = "pyint"

            # Check if this is a method call that returns PyObject
            if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute):
                # Method call - check if it returns PyObject
                if needs_try:
                    # Method returns PyObject (or error union)
                    # Only set if not already determined (e.g., pop() sets to "pyobject", keys() sets to "list")
                    existing_type = self.var_types.get(target.id)
                    # Don't overwrite specific types that were already determined above
                    if existing_type not in ["list", "dict", "pyobject", "pyint"]:
                        self.var_types[target.id] = "string"  # Assume PyObject methods return strings

            if is_first_assignment:
                if needs_try:
                    # Emit assignment with error handling
                    if getattr(self, '_in_try_block', False):
                        self._emit_error_handler_for_stmt(f"{value_code}", f"{var_keyword} {target.id}")
                    else:
                        self.emit(f"{var_keyword} {target.id} = try {value_code};")

                    # If assigning a parameter, incref it (param is owned by caller)
                    if isinstance(node.value, ast.Name) and node.value.id in self.function_params:
                        source_type = self.var_types.get(node.value.id)
                        source_is_pyobject = source_type in ["string", "list", "dict", "pyint"]
                        if source_is_pyobject:
                            self.emit(f"runtime.incref({target.id});")

                    # Get var_type for defer logic below
                    var_type = self.var_types.get(target.id)

                    # Check if it's a class instance (needs deinit) or PyObject (needs decref)
                    # IMPORTANT: Index subscripts (list[i], dict[key]) return borrowed references
                    # but slice subscripts (list[1:3]) return owned references that MUST be decreffed
                    is_borrowed_ref = False
                    if isinstance(node.value, ast.Subscript):
                        # Check if it's an index (borrowed) or slice (owned)
                        if not isinstance(node.value.slice, ast.Slice):
                            # Index operation (list[i], dict["key"]) - borrowed reference
                            is_borrowed_ref = True
                        # Slice operations (list[1:3]) create new objects - need decref

                    # Check if it's a function call returning primitive - no defer needed
                    skip_defer = False
                    if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name):
                        func_name = node.value.func.id
                        if func_name in self.function_signatures:
                            sig = self.function_signatures[func_name]
                            if not sig["returns_pyobject"]:
                                # Primitive return - no defer needed
                                skip_defer = True

                    if var_type and var_type in self.class_definitions:
                        # Class instance - use deinit
                        self.emit(f"defer {target.id}.deinit(allocator);")
                    elif not skip_defer and not is_borrowed_ref:
                        # PyObject that we own - use decref
                        # This includes: literals, function calls, method calls, slicing, etc.
                        # But excludes: index subscripts (borrowed references) and primitive function returns
                        self.emit(f"defer runtime.decref({target.id}, allocator);")
                else:
                    # For var, need explicit type; for const, type is inferred
                    if var_keyword == "var":
                        # Determine type annotation based on tracked type
                        var_type = self.var_types.get(target.id)
                        if var_type == "string" or var_type == "list" or var_type == "dict":
                            type_annotation = "*runtime.PyObject"
                        elif var_type and var_type in self.class_definitions:
                            # Class instance type
                            type_annotation = f"*{var_type}"
                        else:
                            type_annotation = "i64"
                        self.emit(f"{var_keyword} {target.id}: {type_annotation} = {value_code};")

                        # If assigning a parameter, incref it (param is owned by caller)
                        is_pyobject = var_type in ["string", "list", "dict", "pyint"]
                        if is_pyobject and isinstance(node.value, ast.Name) and node.value.id in self.function_params:
                            self.emit(f"runtime.incref({target.id});")
                    else:
                        self.emit(f"{var_keyword} {target.id} = {value_code};")
            else:
                # Reassignment - no var/const keyword
                # If reassigning a PyObject, decref the old value first
                var_type = self.var_types.get(target.id)
                is_pyobject = var_type in ["string", "list", "dict", "pyint"]

                if is_pyobject and needs_try:
                    # Decref old value before reassignment
                    self.emit(f"runtime.decref({target.id}, allocator);")
                    if getattr(self, '_in_try_block', False):
                        self._emit_error_handler_for_stmt(f"{value_code}", f"{target.id}")
                    else:
                        self.emit(f"{target.id} = try {value_code};")
                elif is_pyobject:
                    # Decref old value before reassignment
                    self.emit(f"runtime.decref({target.id}, allocator);")
                    self.emit(f"{target.id} = {value_code};")
                elif needs_try:
                    # Non-PyObject with try
                    if getattr(self, '_in_try_block', False):
                        self._emit_error_handler_for_stmt(f"{value_code}", f"{target.id}")
                    else:
                        self.emit(f"{target.id} = try {value_code};")
                else:
                    # Non-PyObject, non-try (primitives)
                    self.emit(f"{target.id} = {value_code};")

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        """Handle augmented assignment: x += 1, y *= 2, etc."""
        # Get target variable name
        if not isinstance(node.target, ast.Name):
            raise NotImplementedError("Augmented assignment only supports simple variables for now")

        var_name = node.target.id

        # Get target type
        var_type = self.var_types.get(var_name)

        # Generate code for right-hand side
        value_code, value_try = self.visit_expr(node.value)

        # Determine operation
        op_map = {
            ast.Add: "+",
            ast.Sub: "-",
            ast.Mult: "*",
            ast.Div: "/",
            ast.FloorDiv: "//",
            ast.Mod: "%",
            ast.Pow: "**",
            ast.BitAnd: "&",
            ast.BitOr: "|",
            ast.BitXor: "^",
            ast.LShift: "<<",
            ast.RShift: ">>",
        }

        op = op_map.get(type(node.op))
        if op is None:
            raise NotImplementedError(f"Augmented assignment operator {type(node.op).__name__} not supported")

        # Special cases
        if op == "//":
            # Floor division in Zig: @divFloor(a, b)
            if var_type == "int":
                self.emit(f"{var_name} = @divFloor({var_name}, {value_code});")
            else:
                raise NotImplementedError("Floor division only supports int for now")
        elif op == "**":
            # Exponentiation in Zig: std.math.pow
            if var_type == "int":
                # Use the same pattern as BinOp Pow in expressions
                self.emit(f"{var_name} = @as(i64, @intFromFloat(@floor(std.math.pow(f64, @floatFromInt({var_name}), @floatFromInt({value_code})))));")
            else:
                raise NotImplementedError("Exponentiation only supports int for now")
        else:
            # Regular operators: +, -, *, /, %
            if var_type == "int":
                if op == "/":
                    # Integer division in Zig requires @divTrunc
                    self.emit(f"{var_name} = @divTrunc({var_name}, {value_code});")
                elif op == "%":
                    # Modulo in Zig requires @rem
                    self.emit(f"{var_name} = @rem({var_name}, {value_code});")
                else:
                    self.emit(f"{var_name} {op}= {value_code};")
            elif var_type == "string" and op == "+":
                # String concatenation: need to allocate new string
                value_expr = f"try {value_code}" if value_try else value_code
                self.emit(f"const __temp_str = try runtime.PyString.concat(allocator, {var_name}, {value_expr});")
                self.emit(f"runtime.decref({var_name}, allocator);")
                self.emit(f"{var_name} = __temp_str;")
            elif var_type == "list" and op == "+":
                # List concatenation
                value_expr = f"try {value_code}" if value_try else value_code
                self.emit(f"const __temp_list = try runtime.PyList.concat(allocator, {var_name}, {value_expr});")
                self.emit(f"runtime.decref({var_name}, allocator);")
                self.emit(f"{var_name} = __temp_list;")
            else:
                raise NotImplementedError(f"Augmented assignment {op}= not supported for type {var_type}")

    def visit_Expr(self, node: ast.Expr) -> None:
        """Generate expression statement"""
        # Skip docstrings
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            return

        # Special handling for print() calls with string literal arguments
        # to avoid memory leaks by creating temp variables with defer decref
        if isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name) and node.value.func.id == "print":
            if node.value.args and isinstance(node.value.args[0], ast.Constant) and isinstance(node.value.args[0].value, str):
                # Create temp variable for string literal
                string_value = node.value.args[0].value
                temp_var = f"_temp_print_str_{id(node)}"
                self.emit(f"const {temp_var} = try runtime.PyString.create(allocator, \"{string_value}\");")
                self.emit(f"defer runtime.decref({temp_var}, allocator);")
                self.emit(f"_ = std.debug.print(\"{{s}}\\n\", .{{runtime.PyString.getValue({temp_var})}});")
                return
            # Special handling for print() with inline PyObject expressions (method calls, slicing)
            # to avoid memory leaks by extracting to temp variable with defer decref
            elif node.value.args:
                arg = node.value.args[0]
                arg_code, arg_try = self.visit_expr(arg)

                # Detect if this is a PyObject-returning expression (method call, subscript, attribute, or pyobject variable)
                is_method_call = isinstance(arg, ast.Call) and isinstance(arg.func, ast.Attribute)
                is_subscript = isinstance(arg, ast.Subscript)
                is_attribute = isinstance(arg, ast.Attribute)
                is_pyobject_var = isinstance(arg, ast.Name) and self.var_types.get(arg.id) in ["string", "list", "dict", "pyobject"]

                # Check if this is a dict subscript (returns PyObject but arg_try is False)
                is_dict_subscript = False
                if is_subscript and isinstance(arg, ast.Subscript) and isinstance(arg.value, ast.Name):
                    obj_type = self.var_types.get(arg.value.id)
                    is_dict_subscript = (obj_type == "dict")

                # Check if attribute is a PyObject field (not primitive)
                is_pyobject_attribute = False
                if is_attribute and isinstance(arg, ast.Attribute) and isinstance(arg.value, ast.Name):
                    obj_name = arg.value.id
                    obj_type = self.var_types.get(obj_name)
                    if obj_type and obj_type in self.class_definitions:
                        class_info = self.class_definitions[obj_type]
                        field_type = class_info.fields.get(arg.attr)
                        if field_type == "*runtime.PyObject":
                            is_pyobject_attribute = True

                if (arg_try and (is_method_call or is_subscript)) or is_dict_subscript or is_pyobject_attribute or is_pyobject_var:
                    # Determine the type to know how to print
                    arg_type = None
                    is_slice = False
                    if is_subscript and isinstance(arg, ast.Subscript) and isinstance(arg.value, ast.Name):
                        arg_type = self.var_types.get(arg.value.id)
                        is_slice = isinstance(arg.slice, ast.Slice)
                    elif is_method_call and isinstance(arg, ast.Call) and isinstance(arg.func, ast.Attribute) and isinstance(arg.func.value, ast.Name):
                        obj_name = arg.func.value.id
                        arg_type = self.var_types.get(obj_name)
                    elif is_attribute and isinstance(arg, ast.Attribute) and isinstance(arg.value, ast.Name):
                        # Attribute access like dog.name
                        obj_name = arg.value.id
                        obj_type = self.var_types.get(obj_name)
                        # Check if it's a class instance
                        if obj_type and obj_type in self.class_definitions:
                            # Look up the field type in the class definition
                            class_info = self.class_definitions[obj_type]
                            field_type = class_info.fields.get(arg.attr)
                            if field_type == "*runtime.PyObject":
                                arg_type = "string"  # Assume PyObject fields are strings for now
                            elif field_type == "i64":
                                arg_type = "int"  # Primitive int field
                    elif is_pyobject_var and isinstance(arg, ast.Name):
                        # PyObject variable like sound
                        arg_type = self.var_types.get(arg.id)

                    # Extract to temp variable
                    temp_var = f"_temp_print_{id(node)}"
                    # Dict subscripts, pyobject attributes, and pyobject variables don't need try
                    if is_dict_subscript or is_pyobject_attribute or is_pyobject_var:
                        self.emit(f"const {temp_var} = {arg_code};")
                    else:
                        # Emit with error handling
                        if getattr(self, '_in_try_block', False):
                            self._emit_error_handler_for_stmt(f"{arg_code}", f"const {temp_var}")
                        else:
                            self.emit(f"const {temp_var} = try {arg_code};")
                    # Only defer decref for method calls or slices (which create new PyObjects)
                    # PyObject attributes, pyobject variables, and single element subscripts return borrowed references, don't decref them
                    if is_method_call or is_slice:
                        self.emit(f"defer runtime.decref({temp_var}, allocator);")

                    # Print based on type
                    if arg_type == "dict" and not is_slice:
                        # Dict subscript returns PyObject - need to check type at runtime
                        self.emit(f"if ({temp_var}.type_id == .string) {{")
                        self.emit(f'    _ = std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({temp_var})}});')
                        self.emit(f"}} else if ({temp_var}.type_id == .int) {{")
                        self.emit(f'    _ = std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({temp_var})}});')
                        self.emit(f"}} else {{")
                        self.emit(f'    _ = std.debug.print("{{}}\\n", .{{{temp_var}}});')
                        self.emit(f"}}")
                    elif arg_type == "tuple" and not is_slice:
                        # Tuple subscript returns PyObject - need to check type at runtime
                        self.emit(f"if ({temp_var}.type_id == .string) {{")
                        self.emit(f'    _ = std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({temp_var})}});')
                        self.emit(f"}} else if ({temp_var}.type_id == .int) {{")
                        self.emit(f'    _ = std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({temp_var})}});')
                        self.emit(f"}} else {{")
                        self.emit(f'    _ = std.debug.print("{{}}\\n", .{{{temp_var}}});')
                        self.emit(f"}}")
                    elif arg_type == "pyobject":
                        # PyObject variable (like from list.pop()) - need to check type at runtime
                        self.emit(f"if ({temp_var}.type_id == .string) {{")
                        self.emit(f'    _ = std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({temp_var})}});')
                        self.emit(f"}} else if ({temp_var}.type_id == .int) {{")
                        self.emit(f'    _ = std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({temp_var})}});')
                        self.emit(f"}} else {{")
                        self.emit(f'    _ = std.debug.print("{{}}\\n", .{{{temp_var}}});')
                        self.emit(f"}}")
                    elif arg_type == "string" and not is_slice:
                        # String methods or single char subscript return PyString
                        self.emit(f'_ = std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({temp_var})}});')
                    elif is_slice and (arg_type == "list" or arg_type == "tuple"):
                        # List/tuple slice returns list - need to print as list
                        self.emit(f'runtime.printList({temp_var});')
                        self.emit(f'_ = std.debug.print("\\n", .{{}});')
                    elif is_slice and arg_type == "string":
                        # String slice returns string
                        self.emit(f'_ = std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({temp_var})}});')
                    elif (arg_type == "list" or arg_type == "tuple") and not is_slice:
                        # List/tuple single element subscript returns PyInt
                        self.emit(f'_ = std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({temp_var})}});')
                    elif is_method_call and arg_type == "string":
                        # String methods return PyString
                        self.emit(f'_ = std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({temp_var})}});')
                    elif is_subscript and not is_slice:
                        # Unknown type subscript - default to list subscript (returns PyInt)
                        self.emit(f'_ = std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({temp_var})}});')
                    else:
                        # Default: try string first
                        self.emit(f'_ = std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({temp_var})}});')
                    return
        expr_code, needs_try = self.visit_expr(node.value)

        # Unwrap any __WRAP_PRIMITIVE__ markers
        expr_code = self._unwrap_primitive_markers(expr_code, id(node))

        # Expand any __sum_call__ markers
        expr_code = self._expand_sum_markers(expr_code)

        # Handle __print_pyobject__ marker for dict values
        if expr_code.startswith("__print_pyobject__"):
            pyobj_code = expr_code.replace("__print_pyobject__", "")
            temp_var = f"_print_pyobj_{id(node)}"
            self.emit(f"const {temp_var} = {pyobj_code};")
            self.emit(f"if ({temp_var}.type_id == .string) {{")
            self.emit(f'    _ = std.debug.print("{{s}}\\n", .{{runtime.PyString.getValue({temp_var})}});')
            self.emit(f"}} else if ({temp_var}.type_id == .int) {{")
            self.emit(f'    _ = std.debug.print("{{}}\\n", .{{runtime.PyInt.getValue({temp_var})}});')
            self.emit(f"}} else {{")
            self.emit(f'    _ = std.debug.print("{{}}\\n", .{{{temp_var}}});')
            self.emit(f"}}")
            return

        # Special handling for statement methods with primitive args
        if expr_code.startswith("__list_") or expr_code.startswith("__dict_"):
            parts = expr_code.split("__")
            method_type = parts[1]  # "list_reverse", "dict_update", etc
            obj_code = parts[2]

            if len(parts) > 3 and parts[3]:  # Check if args exist (parts[3] not empty)
                # Parse all arguments (format: "arg1|||try1;;;arg2|||try2")
                # Args might contain __ themselves, so rejoin parts[3:]
                args_encoded = "__".join(parts[3:])
                args_list = []
                if args_encoded:
                    for arg_part in args_encoded.split(";;;"):
                        if "|||" in arg_part:
                            arg_code, arg_try_str = arg_part.split("|||", 1)
                            # Unwrap any markers in the argument
                            arg_code = self._unwrap_primitive_markers(arg_code, id(node))
                            args_list.append((arg_code, arg_try_str == "True"))

                # Handle methods by type
                if method_type == "list_append":
                    arg_code, arg_try = args_list[0]
                    if arg_try:
                        self.emit(f"try runtime.PyList.append({obj_code}, {arg_code});")
                    else:
                        temp_var = f"_{method_type}_arg_{id(node)}"
                        self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {arg_code});")
                        self.emit(f"try runtime.PyList.append({obj_code}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")

                elif method_type == "list_remove":
                    arg_code, arg_try = args_list[0]
                    if arg_try:
                        self.emit(f"try runtime.PyList.remove(allocator, {obj_code}, {arg_code});")
                    else:
                        temp_var = f"_{method_type}_arg_{id(node)}"
                        self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {arg_code});")
                        self.emit(f"try runtime.PyList.remove(allocator, {obj_code}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")

                elif method_type == "list_extend":
                    arg_code, arg_try = args_list[0]
                    self.emit(f"try runtime.PyList.extend({obj_code}, {arg_code});")

                elif method_type == "list_insert":
                    # insert has 2 args: index (primitive) and value (any)
                    index_code, index_try = args_list[0]
                    value_code, value_try = args_list[1]

                    if value_try:
                        # Value is already PyObject
                        self.emit(f"try runtime.PyList.insert(allocator, {obj_code}, {index_code}, {value_code});")
                    else:
                        # Value is primitive - wrap it
                        temp_var = f"_{method_type}_val_{id(node)}"
                        self.emit(f"const {temp_var} = try runtime.PyInt.create(allocator, {value_code});")
                        self.emit(f"try runtime.PyList.insert(allocator, {obj_code}, {index_code}, {temp_var});")
                        self.emit(f"runtime.decref({temp_var}, allocator);")

                elif method_type == "list_clear":
                    self.emit(f"runtime.PyList.clear(allocator, {obj_code});")

                # Dict statement methods with args
                elif method_type == "dict_update":
                    arg_code, arg_try = args_list[0]
                    self.emit(f"try runtime.PyDict.update({obj_code}, {arg_code});")

            else:
                # No args (like reverse, sort, clear)
                if method_type == "list_reverse":
                    self.emit(f"runtime.PyList.reverse({obj_code});")
                elif method_type == "list_clear":
                    self.emit(f"runtime.PyList.clear(allocator, {obj_code});")
                elif method_type == "list_sort":
                    self.emit(f"runtime.PyList.sort({obj_code});")
                elif method_type == "dict_clear":
                    self.emit(f"runtime.PyDict.clear(allocator, {obj_code});")
            return

        if needs_try:
            # Emit with error handling
            if getattr(self, '_in_try_block', False):
                self._emit_error_handler_for_stmt(f"{expr_code}", "_")
            else:
                self.emit(f"_ = try {expr_code};")
        else:
            self.emit(f"_ = {expr_code};")



def generate_code(parsed: ParsedModule, imported_modules: Optional[Dict[str, 'ParsedModule']] = None) -> str:
    """Generate Zig code from parsed module"""
    generator = ZigCodeGenerator(imported_modules=imported_modules)
    return generator.generate(parsed)


if __name__ == "__main__":
    import sys
    from core.parser import parse_file, load_all_modules

    if len(sys.argv) < 2:
        print("Usage: python -m core.codegen <file.py>")
        sys.exit(1)

    filepath = sys.argv[1]
    parsed = parse_file(filepath)

    # Load imported modules
    imported_modules = {}
    if parsed.imports:
        imported_modules = load_all_modules(parsed)

    zig_code = generate_code(parsed, imported_modules)

    print(f"✓ Generated Zig code from {filepath}\n")
    print("=" * 60)
    print(zig_code)
    print("=" * 60)
