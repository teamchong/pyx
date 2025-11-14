const std = @import("std");
const ast = @import("ast.zig");
const operators = @import("codegen/operators.zig");
const classes = @import("codegen/classes.zig");
const builtins = @import("codegen/builtins.zig");
const functions = @import("codegen/functions.zig");
const expressions = @import("codegen/expressions.zig");
const statements = @import("codegen/statements.zig");
const control_flow = @import("codegen/control_flow.zig");

/// Codegen errors
pub const CodegenError = error{
    ExpectedModule,
    UnsupportedExpression,
    UnsupportedStatement,
    UnsupportedTarget,
    InvalidAssignment,
    InvalidCompare,
    EmptyTargets,
    UnsupportedFunction,
    UnsupportedCall,
    UnsupportedMethod,
    InvalidArguments,
    UnsupportedForLoop,
    InvalidLoopVariable,
    InvalidRangeArgs,
    InvalidEnumerateArgs,
    InvalidEnumerateTarget,
    InvalidZipArgs,
    InvalidZipTarget,
    MissingLenArg,
    MissingHttpGetArg,
    NotImplemented,
    OutOfMemory,
};

/// Generate Zig code from AST
pub fn generate(allocator: std.mem.Allocator, tree: ast.Node, is_shared_lib: bool) ![]const u8 {
    // Initialize code generator
    var generator = try ZigCodeGenerator.init(allocator, is_shared_lib);
    defer generator.deinit();

    // Generate code from AST
    switch (tree) {
        .module => |module| try generator.generate(module),
        else => return error.ExpectedModule,
    }

    return try generator.output.toOwnedSlice(allocator);
}

/// Expression evaluation result
pub const ExprResult = struct {
    code: []const u8,
    needs_try: bool,
    needs_decref: bool = false,
};

/// Zig code generator - ports Python ZigCodeGenerator class
pub const ZigCodeGenerator = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    temp_allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    indent_level: usize,

    // State tracking (matching Python codegen)
    var_types: std.StringHashMap([]const u8),
    declared_vars: std.StringHashMap(void),
    reassigned_vars: std.StringHashMap(void),
    list_element_types: std.StringHashMap([]const u8),
    tuple_element_types: std.StringHashMap([]const u8),
    function_names: std.StringHashMap(void),
    function_needs_allocator: std.StringHashMap(bool),
    function_return_types: std.StringHashMap([]const u8),
    class_names: std.StringHashMap(void),
    class_has_methods: std.StringHashMap(bool),
    method_return_types: std.StringHashMap([]const u8),

    needs_runtime: bool,
    needs_allocator: bool,
    needs_http: bool,
    needs_python: bool,
    has_async: bool,
    temp_var_counter: usize,
    is_shared_lib: bool, // Generate for shared library (.so) or binary

    pub fn init(allocator: std.mem.Allocator, is_shared_lib: bool) !*ZigCodeGenerator {
        const self = try allocator.create(ZigCodeGenerator);
        const arena = std.heap.ArenaAllocator.init(allocator);
        self.* = ZigCodeGenerator{
            .allocator = allocator,
            .arena = arena,
            .temp_allocator = undefined, // Will be set after arena is in struct
            .output = std.ArrayList(u8){},
            .indent_level = 0,
            .var_types = std.StringHashMap([]const u8).init(allocator),
            .declared_vars = std.StringHashMap(void).init(allocator),
            .reassigned_vars = std.StringHashMap(void).init(allocator),
            .list_element_types = std.StringHashMap([]const u8).init(allocator),
            .tuple_element_types = std.StringHashMap([]const u8).init(allocator),
            .function_names = std.StringHashMap(void).init(allocator),
            .function_needs_allocator = std.StringHashMap(bool).init(allocator),
            .function_return_types = std.StringHashMap([]const u8).init(allocator),
            .class_names = std.StringHashMap(void).init(allocator),
            .class_has_methods = std.StringHashMap(bool).init(allocator),
            .method_return_types = std.StringHashMap([]const u8).init(allocator),
            .needs_runtime = false,
            .needs_allocator = false,
            .needs_http = false,
            .needs_python = false,
            .has_async = false,
            .temp_var_counter = 0,
            .is_shared_lib = is_shared_lib,
        };
        // Set temp_allocator after arena is moved into struct
        self.temp_allocator = self.arena.allocator();
        return self;
    }

    pub fn deinit(self: *ZigCodeGenerator) void {
        self.output.deinit(self.allocator);
        self.var_types.deinit();
        self.declared_vars.deinit();
        self.reassigned_vars.deinit();
        self.list_element_types.deinit();
        self.tuple_element_types.deinit();
        self.function_names.deinit();
        self.function_needs_allocator.deinit();
        self.function_return_types.deinit();
        self.class_names.deinit();
        self.class_has_methods.deinit();
        self.method_return_types.deinit();
        self.arena.deinit(); // Free all temp allocations
        self.allocator.destroy(self);
    }

    /// Emit a line of code with proper indentation
    pub fn emit(self: *ZigCodeGenerator, code: []const u8) CodegenError!void {
        // Add indentation
        for (0..self.indent_level) |_| {
            try self.output.appendSlice(self.allocator, "    ");
        }
        try self.output.appendSlice(self.allocator, code);
        try self.output.append(self.allocator, '\n');
    }

    /// Emit a line and free the owned slice after copying it
    /// Note: Arena allocator will free this automatically on deinit
    pub fn emitOwned(self: *ZigCodeGenerator, code: []const u8) CodegenError!void {
        // No defer needed - arena allocator frees everything at once
        try self.emit(code);
    }

    /// Extract expression to statement if it needs cleanup
    /// This prevents memory leaks in nested expressions like: s1 + " " + s2
    pub fn extractResultToStatement(self: *ZigCodeGenerator, result: ExprResult) CodegenError![]const u8 {
        if (result.needs_decref) {
            const temp_id = self.temp_var_counter;
            self.temp_var_counter += 1;

            var buf = std.ArrayList(u8){};
            if (result.needs_try) {
                try buf.writer(self.temp_allocator).print("const __expr{d} = try {s};", .{ temp_id, result.code });
            } else {
                try buf.writer(self.temp_allocator).print("const __expr{d} = {s};", .{ temp_id, result.code });
            }
            try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));

            var defer_buf = std.ArrayList(u8){};
            try defer_buf.writer(self.temp_allocator).print("defer runtime.decref(__expr{d}, allocator);", .{temp_id});
            try self.emitOwned(try defer_buf.toOwnedSlice(self.temp_allocator));

            var name_buf = std.ArrayList(u8){};
            try name_buf.writer(self.temp_allocator).print("__expr{d}", .{temp_id});
            return try name_buf.toOwnedSlice(self.temp_allocator);
        }
        return result.code;
    }

    /// Increase indentation level
    pub fn indent(self: *ZigCodeGenerator) void {
        self.indent_level += 1;
    }

    /// Decrease indentation level
    pub fn dedent(self: *ZigCodeGenerator) void {
        if (self.indent_level > 0) {
            self.indent_level -= 1;
        }
    }

    /// Emit async executor (simple single-threaded event loop)
    fn emitAsyncExecutor(self: *ZigCodeGenerator) CodegenError!void {
        try self.emit("// Async executor (simple single-threaded event loop)");
        try self.emit("const Executor = struct {");
        self.indent();
        try self.emit("frames: std.ArrayList(*anyopaque),");
        try self.emit("allocator: std.mem.Allocator,");
        try self.emit("");
        try self.emit("pub fn init(allocator: std.mem.Allocator) Executor {");
        self.indent();
        try self.emit("return .{");
        self.indent();
        try self.emit(".frames = std.ArrayList(*anyopaque){},");
        try self.emit(".allocator = allocator,");
        self.dedent();
        try self.emit("};");
        self.dedent();
        try self.emit("}");
        try self.emit("");
        try self.emit("pub fn spawn(self: *Executor, frame: anytype) !void {");
        self.indent();
        try self.emit("try self.frames.append(self.allocator, @ptrCast(frame));");
        self.dedent();
        try self.emit("}");
        try self.emit("");
        try self.emit("pub fn run(self: *Executor) !void {");
        self.indent();
        try self.emit("// Simple: run all frames sequentially for Phase 1");
        try self.emit("for (self.frames.items) |frame_ptr| {");
        self.indent();
        try self.emit("// Resume each frame until complete");
        try self.emit("// (Full async implementation in Phase 2)");
        try self.emit("_ = frame_ptr;");
        self.dedent();
        try self.emit("}");
        self.dedent();
        try self.emit("}");
        try self.emit("");
        try self.emit("pub fn deinit(self: *Executor) void {");
        self.indent();
        try self.emit("self.frames.deinit(self.allocator);");
        self.dedent();
        try self.emit("}");
        self.dedent();
        try self.emit("};");
    }

    /// Generate code from parsed AST
    pub fn generate(self: *ZigCodeGenerator, module: ast.Node.Module) CodegenError!void {
        // Phase 1: Detect runtime needs, collect declarations, and collect function names
        for (module.body) |node| {
            try self.detectRuntimeNeeds(node);
            try self.collectDeclarations(node);

            // Collect function names and detect async
            if (node == .function_def) {
                try self.function_names.put(node.function_def.name, {});
                if (node.function_def.is_async) {
                    self.has_async = true;
                }
            }

            // Collect class names
            if (node == .class_def) {
                try self.class_names.put(node.class_def.name, {});
            }
        }

        // Phase 2: Detect reassignments
        var assignments_seen = std.StringHashMap(void).init(self.allocator);
        defer assignments_seen.deinit();

        for (module.body) |node| {
            try self.detectReassignments(node, &assignments_seen);
        }

        // Reset declared_vars for code generation
        self.declared_vars.clearRetainingCapacity();

        // Phase 3: Generate imports
        try self.emit("const std = @import(\"std\");");
        if (self.needs_runtime) {
            try self.emit("const runtime = @import(\"runtime.zig\");");
        }
        if (self.needs_http) {
            try self.emit("const http = @import(\"http.zig\");");
        }
        if (self.needs_python) {
            try self.emit("const python = @import(\"python.zig\");");
        }
        try self.emit("");

        // Phase 3.5: Generate async executor if needed
        if (self.has_async) {
            try self.emitAsyncExecutor();
            try self.emit("");
        }

        // Phase 4: Generate class and function definitions (before main)
        for (module.body) |node| {
            if (node == .class_def) {
                try classes.visitClassDef(self, node.class_def);
                try self.emit("");
            }
        }

        for (module.body) |node| {
            if (node == .function_def) {
                try self.visitFunctionDef(node.function_def);
                try self.emit("");
            }
        }

        // Phase 5: Generate main function
        // For shared libraries: export pyx_main() for dlsym, returns c_int but can handle errors
        // For binaries: regular main()
        if (self.is_shared_lib) {
            try self.emit("pub export fn pyx_main() callconv(.c) c_int {");
            self.indent();
            try self.emit("_pyx_main_impl() catch |err| {");
            self.indent();
            try self.emit("std.debug.print(\"Error: {any}\\n\", .{err});");
            try self.emit("return 1;");
            self.dedent();
            try self.emit("};");
            try self.emit("return 0;");
            self.dedent();
            try self.emit("}");
            try self.emit("");
            try self.emit("fn _pyx_main_impl() !void {");
        } else {
            try self.emit("pub fn main() !void {");
        }
        self.indent();

        if (self.needs_allocator) {
            try self.emit("var gpa = std.heap.GeneralPurposeAllocator(.{}){};");
            try self.emit("defer _ = gpa.deinit();");
            try self.emit("var allocator = gpa.allocator();");
            try self.emit("_ = &allocator; // Suppress unused warning when no runtime operations need it");
            try self.emit("");
        }

        // Initialize Python interpreter if needed
        if (self.needs_python) {
            try self.emit("try python.initialize();");
            try self.emit("defer python.finalize();");
            try self.emit("");
        }

        // Only visit non-function/class nodes in main
        for (module.body) |node| {
            if (node != .function_def and node != .class_def) {
                try statements.visitNode(self, node);
            }
        }

        // Close _pyx_main_impl() or main()
        self.dedent();
        try self.emit("}");
    }

    /// Detect if node requires PyObject runtime
    fn detectRuntimeNeeds(self: *ZigCodeGenerator, node: ast.Node) CodegenError!void {
        switch (node) {
            .constant => |constant| {
                if (constant.value == .string) {
                    self.needs_runtime = true;
                    self.needs_allocator = true;
                }
            },
            .list => {
                self.needs_runtime = true;
                self.needs_allocator = true;
            },
            .listcomp => |lc| {
                self.needs_runtime = true;
                self.needs_allocator = true;
                try self.detectRuntimeNeedsExpr(lc.elt.*);
                try self.detectRuntimeNeedsExpr(lc.iter.*);
                for (lc.ifs) |cond| {
                    try self.detectRuntimeNeedsExpr(cond);
                }
            },
            .dict => {
                self.needs_runtime = true;
                self.needs_allocator = true;
            },
            .tuple => {
                self.needs_runtime = true;
                self.needs_allocator = true;
            },
            .expr_stmt => |expr_stmt| {
                // Skip docstrings (same as in visitNode)
                const is_docstring = switch (expr_stmt.value.*) {
                    .constant => |c| c.value == .string,
                    else => false,
                };

                if (!is_docstring) {
                    try self.detectRuntimeNeedsExpr(expr_stmt.value.*);
                }
            },
            .assign => |assign| {
                try self.detectRuntimeNeedsExpr(assign.value.*);
            },
            .if_stmt => |if_stmt| {
                // Check condition
                try self.detectRuntimeNeedsExpr(if_stmt.condition.*);
                // Check body
                for (if_stmt.body) |stmt| {
                    try self.detectRuntimeNeeds(stmt);
                }
                // Check else body
                for (if_stmt.else_body) |stmt| {
                    try self.detectRuntimeNeeds(stmt);
                }
            },
            .while_stmt => |while_stmt| {
                try self.detectRuntimeNeedsExpr(while_stmt.condition.*);
                for (while_stmt.body) |stmt| {
                    try self.detectRuntimeNeeds(stmt);
                }
            },
            .for_stmt => |for_stmt| {
                try self.detectRuntimeNeedsExpr(for_stmt.iter.*);
                for (for_stmt.body) |stmt| {
                    try self.detectRuntimeNeeds(stmt);
                }
            },
            .import_stmt => {
                self.needs_python = true;
                self.needs_allocator = true;
            },
            .import_from => {
                self.needs_python = true;
                self.needs_allocator = true;
            },
            else => {},
        }
    }

    /// Detect if expression requires PyObject runtime
    fn detectRuntimeNeedsExpr(self: *ZigCodeGenerator, node: ast.Node) CodegenError!void {
        switch (node) {
            .constant => |constant| {
                if (constant.value == .string) {
                    self.needs_runtime = true;
                    self.needs_allocator = true;
                }
            },
            .list => {
                self.needs_runtime = true;
                self.needs_allocator = true;
            },
            .listcomp => |lc| {
                self.needs_runtime = true;
                self.needs_allocator = true;
                try self.detectRuntimeNeedsExpr(lc.elt.*);
                try self.detectRuntimeNeedsExpr(lc.iter.*);
                for (lc.ifs) |cond| {
                    try self.detectRuntimeNeedsExpr(cond);
                }
            },
            .dict => {
                self.needs_runtime = true;
                self.needs_allocator = true;
            },
            .tuple => {
                self.needs_runtime = true;
                self.needs_allocator = true;
            },
            .call => |call| {
                // Check if this is a runtime function call
                // Note: abs, min, max work on primitives and don't need runtime
                // len, sum, all, any work on PyObjects and need runtime
                switch (call.func.*) {
                    .name => |func_name| {
                        if (std.mem.eql(u8, func_name.id, "sum") or
                            std.mem.eql(u8, func_name.id, "all") or
                            std.mem.eql(u8, func_name.id, "any") or
                            std.mem.eql(u8, func_name.id, "len"))
                        {
                            self.needs_runtime = true;
                        }
                        if (std.mem.eql(u8, func_name.id, "http_get")) {
                            self.needs_http = true;
                            self.needs_runtime = true;
                        }
                        // Check if this is a class method call wrapped in print()
                        // Since we can't easily determine return type here, conservatively assume runtime needed
                        if (self.class_names.contains(func_name.id)) {
                            self.needs_runtime = true;
                            self.needs_allocator = true;
                        }
                    },
                    .attribute => {
                        // Method calls might return primitives that need wrapping
                        // Conservatively mark as needing runtime
                        self.needs_runtime = true;
                        self.needs_allocator = true;
                    },
                    else => {},
                }
                // Recursively check arguments
                for (call.args) |arg| {
                    try self.detectRuntimeNeedsExpr(arg);
                }
            },
            .binop => |binop| {
                try self.detectRuntimeNeedsExpr(binop.left.*);
                try self.detectRuntimeNeedsExpr(binop.right.*);
            },
            .compare => |compare| {
                // Check if 'in' or 'not in' operator is used
                for (compare.ops) |op| {
                    if (op == .In or op == .NotIn) {
                        self.needs_runtime = true;
                        break;
                    }
                }
                // Recursively check left and comparators
                try self.detectRuntimeNeedsExpr(compare.left.*);
                for (compare.comparators) |comp| {
                    try self.detectRuntimeNeedsExpr(comp);
                }
            },
            else => {},
        }
    }

    /// Collect all variable declarations
    fn collectDeclarations(self: *ZigCodeGenerator, node: ast.Node) CodegenError!void {
        switch (node) {
            .assign => |assign| {
                for (assign.targets) |target| {
                    switch (target) {
                        .name => |name| {
                            try self.declared_vars.put(name.id, {});
                        },
                        else => {},
                    }
                }
            },
            .aug_assign => |aug_assign| {
                // Augmented assignment can declare a variable if it doesn't exist
                switch (aug_assign.target.*) {
                    .name => |name| {
                        try self.declared_vars.put(name.id, {});
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    /// Detect variables that are reassigned
    fn detectReassignments(self: *ZigCodeGenerator, node: ast.Node, assignments_seen: *std.StringHashMap(void)) CodegenError!void {
        switch (node) {
            .assign => |assign| {
                for (assign.targets) |target| {
                    switch (target) {
                        .name => |name| {
                            if (assignments_seen.contains(name.id)) {
                                try self.reassigned_vars.put(name.id, {});
                            } else {
                                try assignments_seen.put(name.id, {});
                            }
                        },
                        else => {},
                    }
                }
            },
            .aug_assign => |aug_assign| {
                // Augmented assignment is always a reassignment
                switch (aug_assign.target.*) {
                    .name => |name| {
                        try self.reassigned_vars.put(name.id, {});
                        // Also mark as seen for first assignment
                        if (!assignments_seen.contains(name.id)) {
                            try assignments_seen.put(name.id, {});
                        }
                    },
                    else => {},
                }
            },
            .if_stmt => |if_node| {
                // Traverse if body
                for (if_node.body) |stmt| {
                    try self.detectReassignments(stmt, assignments_seen);
                }
                // Traverse else body
                for (if_node.else_body) |stmt| {
                    try self.detectReassignments(stmt, assignments_seen);
                }
            },
            .while_stmt => |while_node| {
                // Traverse while body
                for (while_node.body) |stmt| {
                    try self.detectReassignments(stmt, assignments_seen);
                }
            },
            .for_stmt => |for_node| {
                // Traverse for body
                for (for_node.body) |stmt| {
                    try self.detectReassignments(stmt, assignments_seen);
                }
            },
            .function_def => |func| {
                // Traverse function body
                for (func.body) |stmt| {
                    try self.detectReassignments(stmt, assignments_seen);
                }
            },
            else => {},
        }
    }

    // Visitor methods

    pub fn visitFunctionDef(self: *ZigCodeGenerator, func: ast.Node.FunctionDef) CodegenError!void {
        return functions.visitFunctionDef(self, func);
    }
};
