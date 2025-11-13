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
    NotImplemented,
    OutOfMemory,
};

/// Generate Zig code from AST
pub fn generate(allocator: std.mem.Allocator, tree: ast.Node) ![]const u8 {
    // Initialize code generator
    var generator = try ZigCodeGenerator.init(allocator);
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
};

/// Zig code generator - ports Python ZigCodeGenerator class
pub const ZigCodeGenerator = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    indent_level: usize,

    // State tracking (matching Python codegen)
    var_types: std.StringHashMap([]const u8),
    declared_vars: std.StringHashMap(void),
    reassigned_vars: std.StringHashMap(void),
    list_element_types: std.StringHashMap([]const u8),
    tuple_element_types: std.StringHashMap([]const u8),
    function_names: std.StringHashMap(void),
    class_names: std.StringHashMap(void),

    needs_runtime: bool,
    needs_allocator: bool,
    temp_var_counter: usize,

    pub fn init(allocator: std.mem.Allocator) !*ZigCodeGenerator {
        const self = try allocator.create(ZigCodeGenerator);
        self.* = ZigCodeGenerator{
            .allocator = allocator,
            .output = std.ArrayList(u8){},
            .indent_level = 0,
            .var_types = std.StringHashMap([]const u8).init(allocator),
            .declared_vars = std.StringHashMap(void).init(allocator),
            .reassigned_vars = std.StringHashMap(void).init(allocator),
            .list_element_types = std.StringHashMap([]const u8).init(allocator),
            .tuple_element_types = std.StringHashMap([]const u8).init(allocator),
            .function_names = std.StringHashMap(void).init(allocator),
            .class_names = std.StringHashMap(void).init(allocator),
            .needs_runtime = false,
            .needs_allocator = false,
            .temp_var_counter = 0,
        };
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
        self.class_names.deinit();
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

    /// Generate code from parsed AST
    pub fn generate(self: *ZigCodeGenerator, module: ast.Node.Module) CodegenError!void {
        // Phase 1: Detect runtime needs, collect declarations, and collect function names
        for (module.body) |node| {
            try self.detectRuntimeNeeds(node);
            try self.collectDeclarations(node);

            // Collect function names
            if (node == .function_def) {
                try self.function_names.put(node.function_def.name, {});
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
        try self.emit("");

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
        try self.emit("pub fn main() !void {");
        self.indent();

        if (self.needs_allocator) {
            try self.emit("var gpa = std.heap.GeneralPurposeAllocator(.{}){};");
            try self.emit("defer _ = gpa.deinit();");
            try self.emit("const allocator = gpa.allocator();");
            try self.emit("");
        }

        // Only visit non-function/class nodes in main
        for (module.body) |node| {
            if (node != .function_def and node != .class_def) {
                try statements.visitNode(self, node);
            }
        }

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
            else => {},
        }
    }

    // Visitor methods

    pub fn visitFunctionDef(self: *ZigCodeGenerator, func: ast.Node.FunctionDef) CodegenError!void {
        return functions.visitFunctionDef(self, func);
    }
};
