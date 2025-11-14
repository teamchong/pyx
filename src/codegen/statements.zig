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

            // Evaluate the value expression
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
                .dict => {
                    try self.var_types.put(var_name, "dict");
                },
                .tuple => {
                    try self.var_types.put(var_name, "tuple");
                },
                .call => |call| {
                    // Check if this is a class instantiation or method call
                    switch (call.func.*) {
                        .name => |func_name| {
                            if (self.class_names.contains(func_name.id)) {
                                try self.var_types.put(var_name, "class");
                                is_class_instance = true;
                                class_name = func_name.id;
                            }
                        },
                        .attribute => |attr| {
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

                            // Methods that return integers
                            const int_methods = [_][]const u8{
                                "count", "index", "find"
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
                    if (needs_defer) {
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
                    if (needs_defer) {
                        var defer_buf = std.ArrayList(u8){};
                        try defer_buf.writer(self.temp_allocator).print("defer runtime.decref({s}, allocator);", .{var_name});
                        try self.emitOwned(try defer_buf.toOwnedSlice(self.temp_allocator));
                    }
                }
            } else {
                // Reassignment
                const var_type = self.var_types.get(var_name);
                if (var_type != null and std.mem.eql(u8, var_type.?, "string")) {
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
                                } else {
                                    try buf.writer(self.temp_allocator).print("{s} = try runtime.PyTuple.getItem({s}, {d});", .{ var_name, value_result.code, i });
                                }
                                try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
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
    self.needs_python = true;

    const alias = import_node.asname orelse import_node.module;

    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print(
        "const {s} = try python.importModule(allocator, \"{s}\");",
        .{ alias, import_node.module }
    );
    try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));

    // Suppress unused warning
    var buf2 = std.ArrayList(u8){};
    try buf2.writer(self.temp_allocator).print("_ = {s};", .{alias});
    try self.emitOwned(try buf2.toOwnedSlice(self.temp_allocator));
}

/// Generate code for from-import statement
fn visitImportFrom(self: *ZigCodeGenerator, import_from: ast.Node.ImportFrom) CodegenError!void {
    self.needs_allocator = true;
    self.needs_python = true;

    for (import_from.names, 0..) |name, i| {
        const alias = if (import_from.asnames[i]) |a| a else name;

        var buf = std.ArrayList(u8){};
        try buf.writer(self.temp_allocator).print(
            "const {s} = try python.importFrom(allocator, \"{s}\", \"{s}\");",
            .{ alias, import_from.module, name }
        );
        try self.emitOwned(try buf.toOwnedSlice(self.temp_allocator));
    }
}

