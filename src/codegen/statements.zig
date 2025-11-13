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
                    try buf.writer(self.allocator).print("{s};", .{result.code});
                    try self.emit(try buf.toOwnedSlice(self.allocator));
                }
            }
        },
        .if_stmt => |if_node| try @import("control_flow.zig").visitIf(self, if_node),
        .for_stmt => |for_node| try @import("control_flow.zig").visitFor(self, for_node),
        .while_stmt => |while_node| try @import("control_flow.zig").visitWhile(self, while_node),
        .function_def => |func| try self.visitFunctionDef(func),
        .return_stmt => |ret| try visitReturn(self, ret),
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
            switch (assign.value.*) {
                .constant => |constant| {
                    switch (constant.value) {
                        .string => try self.var_types.put(var_name, "string"),
                        .int => try self.var_types.put(var_name, "int"),
                        else => {},
                    }
                },
                .binop => {
                    // Binary operation - assume int for now
                    try self.var_types.put(var_name, "int");
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
                .call => |call| {
                    // Check if this is a class instantiation
                    switch (call.func.*) {
                        .name => |func_name| {
                            if (self.class_names.contains(func_name.id)) {
                                try self.var_types.put(var_name, "class");
                                is_class_instance = true;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }

            // Use 'var' for reassigned vars, 'const' otherwise
            // Note: Class instances use 'const' unless reassigned - field mutations don't require 'var' in Zig
            const var_keyword = if (self.reassigned_vars.contains(var_name)) "var" else "const";

            // Generate assignment code
            var buf = std.ArrayList(u8){};

            if (is_first_assignment) {
                if (value_result.needs_try) {
                    try buf.writer(self.allocator).print("{s} {s} = try {s};", .{ var_keyword, var_name, value_result.code });
                    try self.emit(try buf.toOwnedSlice(self.allocator));

                    // Add defer for strings
                    const var_type = self.var_types.get(var_name);
                    if (var_type != null and std.mem.eql(u8, var_type.?, "string")) {
                        var defer_buf = std.ArrayList(u8){};
                        try defer_buf.writer(self.allocator).print("defer runtime.decref({s}, allocator);", .{var_name});
                        try self.emit(try defer_buf.toOwnedSlice(self.allocator));
                    }
                } else {
                    try buf.writer(self.allocator).print("{s} {s} = {s};", .{ var_keyword, var_name, value_result.code });
                    try self.emit(try buf.toOwnedSlice(self.allocator));
                }
            } else {
                // Reassignment
                const var_type = self.var_types.get(var_name);
                if (var_type != null and std.mem.eql(u8, var_type.?, "string")) {
                    var decref_buf = std.ArrayList(u8){};
                    try decref_buf.writer(self.allocator).print("runtime.decref({s}, allocator);", .{var_name});
                    try self.emit(try decref_buf.toOwnedSlice(self.allocator));
                }

                if (value_result.needs_try) {
                    try buf.writer(self.allocator).print("{s} = try {s};", .{ var_name, value_result.code });
                } else {
                    try buf.writer(self.allocator).print("{s} = {s};", .{ var_name, value_result.code });
                }
                try self.emit(try buf.toOwnedSlice(self.allocator));
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
                try buf.writer(self.allocator).print("{s} = try {s};", .{ attr_result.code, value_result.code });
            } else {
                try buf.writer(self.allocator).print("{s} = {s};", .{ attr_result.code, value_result.code });
            }
            try self.emit(try buf.toOwnedSlice(self.allocator));
        },
        else => return error.UnsupportedTarget,
    }
}

fn visitReturn(self: *ZigCodeGenerator, ret: ast.Node.Return) CodegenError!void {
    if (ret.value) |value| {
        const value_result = try expressions.visitExpr(self, value.*);
        var buf = std.ArrayList(u8){};

        if (value_result.needs_try) {
            try buf.writer(self.allocator).print("return try {s};", .{value_result.code});
        } else {
            try buf.writer(self.allocator).print("return {s};", .{value_result.code});
        }

        try self.emit(try buf.toOwnedSlice(self.allocator));
    } else {
        try self.emit("return;");
    }
}
