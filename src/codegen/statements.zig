const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const classes = @import("classes.zig");
const expressions = @import("expressions.zig");

const ZigCodeGenerator = codegen.ZigCodeGenerator;
const ExprResult = codegen.ExprResult;
const CodegenError = codegen.CodegenError;

/// Visit a node and generate code
pub fn visitNode(self: *ZigCodeGenerator, node: ast.Node) CodegenError!void {
    switch (node) {
        .assign => |assign| try visitAssign(self, assign),
        .aug_assign => |aug_assign| try visitAugAssign(self, aug_assign),
        .expr_stmt => |expr_stmt| {
            // Skip docstrings (standalone string constants)
            const is_docstring = switch (expr_stmt.value.*) {
                .constant => |c| c.value == .string,
                else => false,
            };

            if (!is_docstring) {
                const result = try expressions.visitExpr(self, expr_stmt.value.*);
                // Expression statement - emit it with semicolon
                if (result.code.len > 0) {
                    var buf = std.ArrayList(u8){};
                    if (result.needs_try) {
                        try buf.writer(self.temp_allocator).print("try {s};", .{result.code});
                    } else {
                        try buf.writer(self.temp_allocator).print("{s};", .{result.code});
                    }
                    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
                }
            }
        },
        .if_stmt => |if_node| try @import("control_flow.zig").visitIf(self, if_node),
        .for_stmt => |for_node| try @import("control_flow.zig").visitFor(self, for_node),
        .while_stmt => |while_node| try @import("control_flow.zig").visitWhile(self, while_node),
        .function_def => |func| try self.visitFunctionDef(func),
        .return_stmt => |ret| try visitReturn(self, ret),
        .import_stmt => |import_node| try visitImport(self, import_node),
        .import_from => |import_from| try visitImportFrom(self, import_from),
        .assert_stmt => |assert_node| try visitAssert(self, assert_node),
        else => {}, // Ignore other node types for now
    }
}

fn visitAssign(self: *ZigCodeGenerator, assign: ast.Node.Assign) CodegenError!void {
    if (assign.targets.len == 0) return error.EmptyTargets;

    // For now, handle single target
    const target = assign.targets[0];

    switch (target) {
        .name => |name| {
            const var_name = name.id;

            // Determine if this is first assignment or reassignment
            const is_first_assignment = !self.declared_vars.contains(var_name);

            if (is_first_assignment) {
                try self.declared_vars.put(var_name, {});
            }

            // Evaluate the value expression (use current allocator - arena if in loop)
            const value_result = try expressions.visitExpr(self, assign.value.*);

            // Infer type from value and check if it's a class instance
            var is_class_instance = false;
            var class_name: ?[]const u8 = null;
            switch (assign.value.*) {
                .constant => |constant| {
                    switch (constant.value) {
                        .string => try self.var_types.put(var_name, "string"),
                        .int => try self.var_types.put(var_name, "int"),
                        else => {},
                    }
                },
                .binop => |binop| {
                    // Detect string concatenation
                    if (binop.op == .Add) {
                        const is_string_concat = blk: {
                            // Check left operand
                            switch (binop.left.*) {
                                .name => |left_name| {
                                    const left_type = self.var_types.get(left_name.id);
                                    if (left_type != null and std.mem.eql(u8, left_type.?, "string")) {
                                        break :blk true;
                                    }
                                },
                                .constant => |c| {
                                    if (c.value == .string) {
                                        break :blk true;
                                    }
                                },
                                .binop => |left_binop| {
                                    // Nested binop - if it's also an Add, assume string concat
                                    if (left_binop.op == .Add) {
                                        break :blk true;
                                    }
                                },
                                else => {},
                            }
                            // Check right operand if left didn't match
                            switch (binop.right.*) {
                                .name => |right_name| {
                                    const right_type = self.var_types.get(right_name.id);
                                    if (right_type != null and std.mem.eql(u8, right_type.?, "string")) {
                                        break :blk true;
                                    }
                                },
                                .constant => |c| {
                                    if (c.value == .string) {
                                        break :blk true;
                                    }
                                },
                                else => {},
                            }
                            break :blk false;
                        };
                        if (is_string_concat) {
                            try self.var_types.put(var_name, "string");
                        } else {
                            try self.var_types.put(var_name, "int");
                        }
                    } else {
                        // Other binary operations - assume int
                        try self.var_types.put(var_name, "int");
                    }
                },
                .name => |source_name| {
                    // Assigning from another variable - copy its type
                    const source_type = self.var_types.get(source_name.id);
                    if (source_type) |stype| {
                        try self.var_types.put(var_name, stype);
                        is_class_instance = std.mem.eql(u8, stype, "class");
                    }
                },
                .list => {
                    try self.var_types.put(var_name, "list");
                },
                .listcomp => {
                    try self.var_types.put(var_name, "list");
                },
                .dict => {
                    try self.var_types.put(var_name, "dict");
                },
                .tuple => {
                    try self.var_types.put(var_name, "tuple");
                },
                .call => |call| {
                    // Check if this is a class instantiation, method call, or user function call
                    switch (call.func.*) {
                        .name => |func_name| {
                            if (self.class_names.contains(func_name.id)) {
                                // Store the actual class name, not just "class"
                                try self.var_types.put(var_name, func_name.id);
                                is_class_instance = true;
                                class_name = func_name.id;
                            } else if (std.mem.eql(u8, func_name.id, "zip")) {
                                // zip() returns a list
                                try self.var_types.put(var_name, "list");
                            } else if (std.mem.eql(u8, func_name.id, "type")) {
                                // type() returns a string
                                try self.var_types.put(var_name, "string");
                            } else if (self.function_return_types.get(func_name.id)) |return_type| {
                                // User-defined function - track return type
                                if (std.mem.eql(u8, return_type, "*runtime.PyObject")) {
                                    try self.var_types.put(var_name, "pyobject");
                                } else if (std.mem.eql(u8, return_type, "i64")) {
                                    try self.var_types.put(var_name, "int");
                                } else if (std.mem.eql(u8, return_type, "void")) {
                                    // void return - don't track type
                                }
                            }
                        },
                        .attribute => |attr| {
                            // Check if this is a Python module function call (e.g., np.array)
                            const is_python_call = blk: {
                                if (attr.value.* == .name) {
                                    if (self.imported_modules.contains(attr.value.name.id)) {
                                        break :blk true;
                                    }
                                }
                                break :blk false;
                            };

                            // Track Python FFI variables for print detection
                            if (is_python_call) {
                                try self.python_ffi_vars.put(var_name, {});
                            }

                            // Skip type tracking for Python C API function calls
                            // These return *anyopaque and are managed by Python's refcounting
                            if (!is_python_call) {
                                // Method call - determine return type based on method name
                                const method_name = attr.attr;

                                // String methods that return strings
                                const string_methods = [_][]const u8{
                                    "upper", "lower", "strip", "lstrip", "rstrip",
                                    "replace", "capitalize", "title", "swapcase"
                                };

                                // List methods that return lists
                                const list_methods = [_][]const u8{
                                    "copy", "reversed"
                                };

                                // Methods that return primitive integers (not PyObjects)
                                const int_methods = [_][]const u8{
                                    "index",  // List.index() returns primitive i64
                                    "count"   // List.count() returns primitive i64
                                };

                                // Check if it's a string method
                                var is_string_method = false;
                                for (string_methods) |sm| {
                                    if (std.mem.eql(u8, method_name, sm)) {
                                        is_string_method = true;
                                        break;
                                    }
                                }

                                if (is_string_method) {
                                    try self.var_types.put(var_name, "string");
                                } else {
                                    // Check if it's a list method
                                    var is_list_method = false;
                                    for (list_methods) |lm| {
                                        if (std.mem.eql(u8, method_name, lm)) {
                                            is_list_method = true;
                                            break;
                                        }
                                    }

                                    if (is_list_method) {
                                        try self.var_types.put(var_name, "list");
                                    } else if (std.mem.eql(u8, method_name, "split")) {
                                        // split() returns a list
                                        try self.var_types.put(var_name, "list");
                                    } else {
                                        // Check if it's an int method
                                        var is_int_method = false;
                                        for (int_methods) |im| {
                                            if (std.mem.eql(u8, method_name, im)) {
                                                is_int_method = true;
                                                break;
                                            }
                                        }

                                        if (is_int_method) {
                                            try self.var_types.put(var_name, "int");
                                        } else {
                                            // Default to pyobject for unknown methods
                                            try self.var_types.put(var_name, "pyobject");
                                        }
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                },
                .subscript => {
                    // Subscript returns PyObject - needs runtime type detection when printing
                    try self.var_types.put(var_name, "pyobject");
                },
                else => {},
            }

            // Use 'var' for reassigned vars or class instances with methods
            // Class instances with methods need 'var' because calling methods that take *T requires mutability
            const needs_var_for_class = if (is_class_instance and class_name != null)
                (self.class_has_methods.get(class_name.?) orelse false)
            else
                false;
            const var_keyword = if (self.reassigned_vars.contains(var_name) or needs_var_for_class) "var" else "const";

            // Generate assignment code
            var buf = std.ArrayList(u8){};

            if (is_first_assignment) {
                if (value_result.needs_try) {
                    try buf.writer(self.temp_allocator).print("{s} {s} = try {s};", .{ var_keyword, var_name, value_result.code });
                    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));

                    // Add defer for strings and PyObjects
                    const var_type = self.var_types.get(var_name);
                    const needs_defer = value_result.needs_decref or (var_type != null and (
                        std.mem.eql(u8, var_type.?, "string") or
                        std.mem.eql(u8, var_type.?, "pyobject") or
                        std.mem.eql(u8, var_type.?, "list") or
                        std.mem.eql(u8, var_type.?, "dict") or
                        std.mem.eql(u8, var_type.?, "tuple")
                    ));

                    // Don't add defer if:
                    // - Variable declared inside loop (arena cleans up)
                    // - Variable will be reassigned (may get arena memory assigned)
                    const will_be_reassigned = blk: {
                        const lifetime = self.semantic_info.lifetimes.get(var_name);
                        break :blk if (lifetime) |lt| lt.reassignment_count > 0 else false;
                    };

                    if (needs_defer and !self.in_loop and !will_be_reassigned) {
                        var defer_buf = std.ArrayList(u8){};
                        try defer_buf.writer(self.temp_allocator).print("defer runtime.decref({s}, allocator);", .{var_name});
                        try self.emitOwned(try defer_buf.toOwnedSlice(self.temp_allocator));
                    }
                } else {
                    // Add explicit type for 'var' declarations
                    const var_type = self.var_types.get(var_name);
                    const is_var = std.mem.eql(u8, var_keyword, "var");

                    if (is_var and var_type != null and std.mem.eql(u8, var_type.?, "int")) {
                        try buf.writer(self.temp_allocator).print("{s} {s}: i64 = {s};", .{ var_keyword, var_name, value_result.code });
                    } else {
                        try buf.writer(self.temp_allocator).print("{s} {s} = {s};", .{ var_keyword, var_name, value_result.code });
                    }
                    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));

                    // Add defer for list/dict/tuple (which don't use needs_try) or if needs_decref is set
                    const needs_defer = value_result.needs_decref or (var_type != null and (
                        std.mem.eql(u8, var_type.?, "list") or
                        std.mem.eql(u8, var_type.?, "dict") or
                        std.mem.eql(u8, var_type.?, "tuple")
                    ));

                    // Don't add defer if:
                    // - Variable declared inside loop (arena cleans up)
                    // - Variable will be reassigned (may get arena memory assigned)
                    const will_be_reassigned = blk: {
                        const lifetime = self.semantic_info.lifetimes.get(var_name);
                        break :blk if (lifetime) |lt| lt.reassignment_count > 0 else false;
                    };

                    if (needs_defer and !self.in_loop and !will_be_reassigned) {
                        var defer_buf = std.ArrayList(u8){};
                        try defer_buf.writer(self.temp_allocator).print("defer runtime.decref({s}, allocator);", .{var_name});
                        try self.emitOwned(try defer_buf.toOwnedSlice(self.temp_allocator));
                    }
                }
            } else {
                // Reassignment
                // Skip decref for ALL loop reassignments (arena or defer will clean up)
                // This trades memory for performance - intermediate values may leak until scope end
                const var_type = self.var_types.get(var_name);
                const is_pyobject = var_type != null and (
                    std.mem.eql(u8, var_type.?, "string") or
                    std.mem.eql(u8, var_type.?, "list") or
                    std.mem.eql(u8, var_type.?, "dict") or
                    std.mem.eql(u8, var_type.?, "tuple") or
                    std.mem.eql(u8, var_type.?, "pyobject")
                );

                // Only add decref if NOT in loop
                if (is_pyobject and !self.in_loop) {
                    var decref_buf = std.ArrayList(u8){};
                    try decref_buf.writer(self.temp_allocator).print("runtime.decref({s}, allocator);", .{var_name});
                    try self.emitOwned(try decref_buf.toOwnedSlice(self.temp_allocator));
                }

                if (value_result.needs_try) {
                    try buf.writer(self.temp_allocator).print("{s} = try {s};", .{ var_name, value_result.code });
                } else {
                    try buf.writer(self.temp_allocator).print("{s} = {s};", .{ var_name, value_result.code });
                }
                try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
            }
        },
        .attribute => |attr| {
            // Handle attribute assignment like self.value = expr
            // Generate the attribute expression (e.g., "self.value")
            const attr_result = try classes.visitAttribute(self, attr);

            // Evaluate the value expression
            const value_result = try expressions.visitExpr(self, assign.value.*);

            // Generate assignment code: attr = value;
            var buf = std.ArrayList(u8){};
            if (value_result.needs_try) {
                try buf.writer(self.temp_allocator).print("{s} = try {s};", .{ attr_result.code, value_result.code });
            } else {
                try buf.writer(self.temp_allocator).print("{s} = {s};", .{ attr_result.code, value_result.code });
            }
            try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
        },
        .tuple => |targets| {
            // Handle tuple unpacking: a, b = (1, 2) or a, b = t
            switch (assign.value.*) {
                .tuple => |values| {
                    // Unpacking from tuple literal
                    if (targets.elts.len != values.elts.len) {
                        return error.InvalidAssignment;
                    }

                    // Generate individual assignments for each target-value pair
                    for (targets.elts, values.elts) |target_node, value_node| {
                        switch (target_node) {
                            .name => |name| {
                                const var_name = name.id;

                                // Determine if this is first assignment
                                const is_first_assignment = !self.declared_vars.contains(var_name);
                                if (is_first_assignment) {
                                    try self.declared_vars.put(var_name, {});
                                }

                                // Infer type from value
                                switch (value_node) {
                                    .constant => |constant| {
                                        switch (constant.value) {
                                            .string => try self.var_types.put(var_name, "string"),
                                            .int => try self.var_types.put(var_name, "int"),
                                            else => {},
                                        }
                                    },
                                    else => {},
                                }

                                // Evaluate the individual value
                                const val_result = try expressions.visitExpr(self, value_node);

                                // Use 'const' for first assignment
                                const var_keyword = if (self.reassigned_vars.contains(var_name)) "var" else "const";

                                // Generate assignment code
                                var buf = std.ArrayList(u8){};
                                if (is_first_assignment) {
                                    if (val_result.needs_try) {
                                        try buf.writer(self.temp_allocator).print("{s} {s} = try {s};", .{ var_keyword, var_name, val_result.code });
                                    } else {
                                        try buf.writer(self.temp_allocator).print("{s} {s} = {s};", .{ var_keyword, var_name, val_result.code });
                                    }
                                } else {
                                    if (val_result.needs_try) {
                                        try buf.writer(self.temp_allocator).print("{s} = try {s};", .{ var_name, val_result.code });
                                    } else {
                                        try buf.writer(self.temp_allocator).print("{s} = {s};", .{ var_name, val_result.code });
                                    }
                                }
                                try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
                            },
                            else => return error.UnsupportedTarget,
                        }
                    }
                },
                .name => {
                    // Unpacking from tuple variable: a, b = t
                    const value_result = try expressions.visitExpr(self, assign.value.*);

                    // Generate unpacking code for each target
                    for (targets.elts, 0..) |target_node, i| {
                        switch (target_node) {
                            .name => |name| {
                                const var_name = name.id;

                                // Determine if this is first assignment
                                const is_first_assignment = !self.declared_vars.contains(var_name);
                                if (is_first_assignment) {
                                    try self.declared_vars.put(var_name, {});
                                }

                                // Mark as pyobject since we're unpacking from PyObject
                                try self.var_types.put(var_name, "pyobject");

                                // Use 'const' for first assignment
                                const var_keyword = if (self.reassigned_vars.contains(var_name)) "var" else "const";

                                // Generate code to extract from tuple
                                var buf = std.ArrayList(u8){};
                                if (is_first_assignment) {
                                    try buf.writer(self.temp_allocator).print("{s} {s} = try runtime.PyTuple.getItem({s}, {d});", .{ var_keyword, var_name, value_result.code, i });
                                    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));

                                    // Add defer for PyObject (only if not in loop - arena will handle cleanup)
                                    if (!self.in_loop) {
                                        var defer_buf = std.ArrayList(u8){};
                                        try defer_buf.writer(self.temp_allocator).print("defer runtime.decref({s}, allocator);", .{var_name});
                                        try self.emitOwned(try defer_buf.toOwnedSlice(self.temp_allocator));
                                    }
                                } else {
                                    try buf.writer(self.temp_allocator).print("{s} = try runtime.PyTuple.getItem({s}, {d});", .{ var_name, value_result.code, i });
                                    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
                                }
                            },
                            else => return error.UnsupportedTarget,
                        }
                    }
                },
                else => return error.UnsupportedTarget,
            }
        },
        else => return error.UnsupportedTarget,
    }
}

fn visitAugAssign(self: *ZigCodeGenerator, aug_assign: ast.Node.AugAssign) CodegenError!void {
    // Get target variable name
    const var_name = switch (aug_assign.target.*) {
        .name => |name| name.id,
        else => return error.UnsupportedTarget,
    };

    // Mark variable as reassigned
    if (!self.reassigned_vars.contains(var_name)) {
        try self.reassigned_vars.put(var_name, {});
    }

    // Evaluate the value expression
    const value_result = try expressions.visitExpr(self, aug_assign.value.*);

    // Determine if this is a primitive type or PyObject
    const var_type = self.var_types.get(var_name);
    const is_primitive = if (var_type) |vtype| std.mem.eql(u8, vtype, "int") else false;

    var buf = std.ArrayList(u8){};

    if (is_primitive) {
        // For primitives, use direct Zig operators
        const op_str = switch (aug_assign.op) {
            .Add => "+=",
            .Sub => "-=",
            .Mult => "*=",
            .Div => "/=",
            .FloorDiv => "//=", // Will need custom handling
            .Mod => "%=",
            .Pow => "**=", // Will need custom handling
            else => return error.UnsupportedExpression,
        };

        // Handle special cases that don't have direct Zig equivalents
        if (aug_assign.op == .FloorDiv) {
            // x //= y → x = @divFloor(x, y)
            if (value_result.needs_try) {
                try buf.writer(self.temp_allocator).print("{s} = @divFloor({s}, try {s});", .{ var_name, var_name, value_result.code });
            } else {
                try buf.writer(self.temp_allocator).print("{s} = @divFloor({s}, {s});", .{ var_name, var_name, value_result.code });
            }
        } else if (aug_assign.op == .Pow) {
            // x **= y → x = std.math.pow(i64, x, y)
            if (value_result.needs_try) {
                try buf.writer(self.temp_allocator).print("{s} = std.math.pow(i64, {s}, try {s});", .{ var_name, var_name, value_result.code });
            } else {
                try buf.writer(self.temp_allocator).print("{s} = std.math.pow(i64, {s}, {s});", .{ var_name, var_name, value_result.code });
            }
        } else if (aug_assign.op == .Mod) {
            // x %= y → x = @rem(x, y) for signed integers in Zig
            if (value_result.needs_try) {
                try buf.writer(self.temp_allocator).print("{s} = @rem({s}, try {s});", .{ var_name, var_name, value_result.code });
            } else {
                try buf.writer(self.temp_allocator).print("{s} = @rem({s}, {s});", .{ var_name, var_name, value_result.code });
            }
        } else {
            // Standard operators: +=, -=, *=, /=
            if (value_result.needs_try) {
                try buf.writer(self.temp_allocator).print("{s} {s} try {s};", .{ var_name, op_str, value_result.code });
            } else {
                try buf.writer(self.temp_allocator).print("{s} {s} {s};", .{ var_name, op_str, value_result.code });
            }
        }
    } else {
        // For PyObjects (string, list, dict, etc.), use runtime functions
        // Determine the specific type to use the right function
        const is_string = if (var_type) |vtype| std.mem.eql(u8, vtype, "string") else false;
        const is_list = if (var_type) |vtype| std.mem.eql(u8, vtype, "list") else false;

        // Only Add is supported for PyObjects currently (string/list concatenation)
        if (aug_assign.op != .Add) {
            return error.UnsupportedExpression;
        }

        // Generate temp variable to hold old value, concat, then decref old
        // This avoids use-after-free: old_x = x; x = concat(old_x, y); decref(old_x);
        const temp_var_name = try std.fmt.allocPrint(self.temp_allocator, "__aug_old_{d}", .{self.temp_var_counter});
        self.temp_var_counter += 1;

        // Save old value: const __aug_old_0 = x;
        var save_buf = std.ArrayList(u8){};
        try save_buf.writer(self.temp_allocator).print("const {s} = {s};", .{ temp_var_name, var_name });
        try self.emitOwned(try save_buf.toOwnedSlice(self.temp_allocator));

        // Generate appropriate concatenation based on type
        if (is_string) {
            // x = runtime.PyString.concat(current_allocator, __aug_old_0, y)
            if (value_result.needs_try) {
                try buf.writer(self.temp_allocator).print("{s} = try runtime.PyString.concat({s}, {s}, try {s});", .{ var_name, self.current_allocator, temp_var_name, value_result.code });
            } else {
                try buf.writer(self.temp_allocator).print("{s} = try runtime.PyString.concat({s}, {s}, {s});", .{ var_name, self.current_allocator, temp_var_name, value_result.code });
            }
        } else if (is_list) {
            // x = runtime.PyList.concat(current_allocator, __aug_old_0, y)
            if (value_result.needs_try) {
                try buf.writer(self.temp_allocator).print("{s} = try runtime.PyList.concat({s}, {s}, try {s});", .{ var_name, self.current_allocator, temp_var_name, value_result.code });
            } else {
                try buf.writer(self.temp_allocator).print("{s} = try runtime.PyList.concat({s}, {s}, {s});", .{ var_name, self.current_allocator, temp_var_name, value_result.code });
            }
        } else {
            // Unknown type - error
            return error.UnsupportedExpression;
        }
        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));

        // Decref old value after reassignment: runtime.decref(__aug_old_0, allocator);
        var decref_buf = std.ArrayList(u8){};
        try decref_buf.writer(self.temp_allocator).print("runtime.decref({s}, allocator);", .{temp_var_name});
        try self.emitOwned(try decref_buf.toOwnedSlice(self.temp_allocator));
        return;
    }

    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
}

fn visitReturn(self: *ZigCodeGenerator, ret: ast.Node.Return) CodegenError!void {
    if (ret.value) |value| {
        const value_result = try expressions.visitExpr(self, value.*);
        var buf = std.ArrayList(u8){};

        if (value_result.needs_try) {
            try buf.writer(self.temp_allocator).print("return try {s};", .{value_result.code});
        } else {
            try buf.writer(self.temp_allocator).print("return {s};", .{value_result.code});
        }

        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    } else {
        try self.emit("return;");
    }
}

/// Generate code for import statement
fn visitImport(self: *ZigCodeGenerator, import_node: ast.Node.Import) CodegenError!void {
    self.needs_allocator = true;

    const alias = import_node.asname orelse import_node.module;

    // Special handling for native modules (json, http, asyncio)
    const is_native_module = std.mem.eql(u8, import_node.module, "json") or
        std.mem.eql(u8, import_node.module, "http") or
        std.mem.eql(u8, import_node.module, "asyncio");

    if (is_native_module) {
        // For native modules, just create a marker - we'll handle method calls specially
        // No actual import needed since functions are in runtime
        var buf = std.ArrayList(u8){};
        try buf.writer(self.temp_allocator).print("// Native module: {s}", .{import_node.module});
        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    } else {
        // Python package - use Zig C interop to call Python C API directly
        // Import using @cImport for the Python module
        var buf = std.ArrayList(u8){};
        try buf.writer(self.temp_allocator).print(
            "// TODO: Implement Zig C interop for {s}\n" ++
            "// const {s} = @cImport({{ @cInclude(\"{s}.h\"); }});",
            .{ import_node.module, alias, import_node.module }
        );
        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    }

    // Track this module name for attribute access
    try self.imported_modules.put(alias, {});

    // Don't add discard statement - module will be used for attribute access
}

/// Generate code for from-import statement
fn visitImportFrom(self: *ZigCodeGenerator, import_from: ast.Node.ImportFrom) CodegenError!void {
    self.needs_allocator = true;

    // Python package - use Zig C interop
    for (import_from.names, 0..) |name, i| {
        const alias = if (import_from.asnames[i]) |a| a else name;

        var buf = std.ArrayList(u8){};
        try buf.writer(self.temp_allocator).print(
            "// TODO: Implement Zig C interop for {s}.{s}\n" ++
            "// const {s} = @cImport({{ @cInclude(\"{s}.h\"); }}).{s};",
            .{ import_from.module, name, alias, import_from.module, name }
        );
        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    }
}

/// Generate code for assert statement
fn visitAssert(self: *ZigCodeGenerator, assert_node: ast.Node.Assert) CodegenError!void {
    // Evaluate the condition
    const condition_result = try expressions.visitExpr(self, assert_node.condition.*);

    var buf = std.ArrayList(u8){};

    // Generate if (!condition) { error }
    try buf.writer(self.temp_allocator).print("if (!({s})) {{", .{condition_result.code});
    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    self.indent();

    // Print error message
    if (assert_node.msg) |msg| {
        const msg_result = try expressions.visitExpr(self, msg.*);

        // Check if message is a string constant
        const is_string_const = switch (msg.*) {
            .constant => |c| c.value == .string,
            else => false,
        };

        var print_buf = std.ArrayList(u8){};
        if (is_string_const) {
            // Extract raw string from PyString.create() call
            const start_quote = std.mem.indexOf(u8, msg_result.code, "\"");
            if (start_quote) |start| {
                const end_quote = std.mem.lastIndexOf(u8, msg_result.code, "\"");
                if (end_quote) |end| {
                    const raw_string = msg_result.code[start..end + 1];
                    try print_buf.writer(self.temp_allocator).print("std.debug.print(\"AssertionError: {{s}}\\n\", .{{{s}}});", .{raw_string});
                } else {
                    try print_buf.writer(self.temp_allocator).writeAll("std.debug.print(\"AssertionError\\n\", .{});");
                }
            } else {
                try print_buf.writer(self.temp_allocator).writeAll("std.debug.print(\"AssertionError\\n\", .{});");
            }
        } else {
            try print_buf.writer(self.temp_allocator).writeAll("std.debug.print(\"AssertionError\\n\", .{});");
        }
        try self.emitOwned(try print_buf.toOwnedSlice(self.temp_allocator));
    } else {
        try self.emit("std.debug.print(\"AssertionError\\n\", .{});");
    }

    // Return error
    try self.emit("return error.AssertionError;");

    self.dedent();
    try self.emit("}");
}

