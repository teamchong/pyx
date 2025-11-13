const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const statements = @import("statements.zig");
const expressions = @import("expressions.zig");

const ZigCodeGenerator = codegen.ZigCodeGenerator;
const CodegenError = codegen.CodegenError;

pub fn visitIf(self: *ZigCodeGenerator, if_node: ast.Node.If) CodegenError!void {
    const test_result = try expressions.visitExpr(self, if_node.condition.*);

    var buf = std.ArrayList(u8){};
    try buf.writer(self.allocator).print("if ({s}) {{", .{test_result.code});
    try self.emit(try buf.toOwnedSlice(self.allocator));

    self.indent();

    for (if_node.body) |stmt| {
        try statements.visitNode(self, stmt);
    }

    self.dedent();

    if (if_node.else_body.len > 0) {
        try self.emit("} else {");
        self.indent();

        for (if_node.else_body) |stmt| {
            try statements.visitNode(self, stmt);
        }

        self.dedent();
    }

    try self.emit("}");
}

pub fn visitFor(self: *ZigCodeGenerator, for_node: ast.Node.For) CodegenError!void {
    // Check if this is a special function call (range, enumerate, zip)
    switch (for_node.iter.*) {
        .call => |call| {
            switch (call.func.*) {
                .name => |func_name| {
                    if (std.mem.eql(u8, func_name.id, "range")) {
                        return visitRangeFor(self, for_node, call.args);
                    } else if (std.mem.eql(u8, func_name.id, "enumerate")) {
                        return visitEnumerateFor(self, for_node, call.args);
                    } else if (std.mem.eql(u8, func_name.id, "zip")) {
                        return visitZipFor(self, for_node, call.args);
                    }
                },
                else => {},
            }
        },
        else => {},
    }

    return error.UnsupportedForLoop;
}

fn visitRangeFor(self: *ZigCodeGenerator, for_node: ast.Node.For, args: []ast.Node) CodegenError!void {
    // Get loop variable name
    switch (for_node.target.*) {
        .name => |target_name| {
            const loop_var = target_name.id;
            try self.var_types.put(loop_var, "int");

            // Parse range arguments
            var start: []const u8 = "0";
            var end: []const u8 = undefined;
            var step: []const u8 = "1";

            if (args.len == 1) {
                const end_result = try expressions.visitExpr(self, args[0]);
                end = end_result.code;
            } else if (args.len == 2) {
                const start_result = try expressions.visitExpr(self, args[0]);
                const end_result = try expressions.visitExpr(self, args[1]);
                start = start_result.code;
                end = end_result.code;
            } else if (args.len == 3) {
                const start_result = try expressions.visitExpr(self, args[0]);
                const end_result = try expressions.visitExpr(self, args[1]);
                const step_result = try expressions.visitExpr(self, args[2]);
                start = start_result.code;
                end = end_result.code;
                step = step_result.code;
            } else {
                return error.InvalidRangeArgs;
            }

            // Check if loop variable already declared
            const is_first_use = !self.declared_vars.contains(loop_var);

            var buf = std.ArrayList(u8){};

            if (is_first_use) {
                try buf.writer(self.allocator).print("var {s}: i64 = {s};", .{ loop_var, start });
                try self.emit(try buf.toOwnedSlice(self.allocator));
                try self.declared_vars.put(loop_var, {});
            } else {
                try buf.writer(self.allocator).print("{s} = {s};", .{ loop_var, start });
                try self.emit(try buf.toOwnedSlice(self.allocator));
            }

            buf = std.ArrayList(u8){};
            try buf.writer(self.allocator).print("while ({s} < {s}) {{", .{ loop_var, end });
            try self.emit(try buf.toOwnedSlice(self.allocator));

            self.indent();

            for (for_node.body) |stmt| {
                try statements.visitNode(self, stmt);
            }

            buf = std.ArrayList(u8){};
            try buf.writer(self.allocator).print("{s} += {s};", .{ loop_var, step });
            try self.emit(try buf.toOwnedSlice(self.allocator));

            self.dedent();
            try self.emit("}");
        },
        else => return error.InvalidLoopVariable,
    }
}

fn visitEnumerateFor(self: *ZigCodeGenerator, for_node: ast.Node.For, args: []ast.Node) CodegenError!void {
    if (args.len != 1) return error.InvalidEnumerateArgs;

    // Get the iterable expression
    const iterable_result = try expressions.visitExpr(self, args[0]);

    // Extract target variables (should be tuple: index, value)
    switch (for_node.target.*) {
        .list => |target_list| {
            if (target_list.elts.len != 2) return error.InvalidEnumerateTarget;

            // Get index and value variable names
            const idx_name = switch (target_list.elts[0]) {
                .name => |n| n.id,
                else => return error.InvalidEnumerateTarget,
            };
            const val_name = switch (target_list.elts[1]) {
                .name => |n| n.id,
                else => return error.InvalidEnumerateTarget,
            };

            // Register variable types
            try self.var_types.put(idx_name, "int");
            try self.var_types.put(val_name, "auto");

            // Generate temporary variable to hold the casted list data
            const list_data_var = try std.fmt.allocPrint(self.allocator, "__enum_list_{d}", .{self.temp_var_counter});
            self.temp_var_counter += 1;

            // Cast PyObject to PyList to access items
            var cast_buf = std.ArrayList(u8){};
            try cast_buf.writer(self.allocator).print("const {s}: *runtime.PyList = @ptrCast(@alignCast({s}.data));", .{ list_data_var, iterable_result.code });
            try self.emit(try cast_buf.toOwnedSlice(self.allocator));

            // Generate: for (list_data.items.items, 0..) |val, idx| {
            var buf = std.ArrayList(u8){};
            try buf.writer(self.allocator).print("for ({s}.items.items, 0..) |{s}, {s}| {{", .{ list_data_var, val_name, idx_name });
            try self.emit(try buf.toOwnedSlice(self.allocator));

            // Mark variables as declared
            try self.declared_vars.put(idx_name, {});
            try self.declared_vars.put(val_name, {});

            self.indent();

            for (for_node.body) |stmt| {
                try statements.visitNode(self, stmt);
            }

            self.dedent();
            try self.emit("}");
        },
        else => return error.InvalidEnumerateTarget,
    }
}

fn visitZipFor(self: *ZigCodeGenerator, for_node: ast.Node.For, args: []ast.Node) CodegenError!void {
    if (args.len < 2) return error.InvalidZipArgs;

    // Get all iterable expressions
    var iterables = std.ArrayList([]const u8){};
    defer iterables.deinit(self.allocator);

    for (args) |arg| {
        const iterable_result = try expressions.visitExpr(self, arg);
        try iterables.append(self.allocator, iterable_result.code);
    }

    // Extract target variables (should be tuple)
    switch (for_node.target.*) {
        .list => |target_list| {
            if (target_list.elts.len != args.len) return error.InvalidZipTarget;

            // Get all variable names
            var var_names = std.ArrayList([]const u8){};
            defer var_names.deinit(self.allocator);

            for (target_list.elts) |elt| {
                const var_name = switch (elt) {
                    .name => |n| n.id,
                    else => return error.InvalidZipTarget,
                };
                try var_names.append(self.allocator, var_name);
                try self.var_types.put(var_name, "auto");
                try self.declared_vars.put(var_name, {});
            }

            // Generate: for (list1.list.items.items, list2.list.items.items, ...) |var1, var2, ...| {
            var buf = std.ArrayList(u8){};
            try buf.writer(self.allocator).writeAll("for (");

            for (iterables.items, 0..) |iterable, i| {
                if (i > 0) try buf.writer(self.allocator).writeAll(", ");
                try buf.writer(self.allocator).print("{s}.list.items.items", .{iterable});
            }

            try buf.writer(self.allocator).writeAll(") |");

            for (var_names.items, 0..) |var_name, i| {
                if (i > 0) try buf.writer(self.allocator).writeAll(", ");
                try buf.writer(self.allocator).writeAll(var_name);
            }

            try buf.writer(self.allocator).writeAll("| {");
            try self.emit(try buf.toOwnedSlice(self.allocator));

            self.indent();

            for (for_node.body) |stmt| {
                try statements.visitNode(self, stmt);
            }

            self.dedent();
            try self.emit("}");
        },
        else => return error.InvalidZipTarget,
    }
}

pub fn visitWhile(self: *ZigCodeGenerator, while_node: ast.Node.While) CodegenError!void {
    const test_result = try expressions.visitExpr(self, while_node.condition.*);

    var buf = std.ArrayList(u8){};
    try buf.writer(self.allocator).print("while ({s}) {{", .{test_result.code});
    try self.emit(try buf.toOwnedSlice(self.allocator));

    self.indent();

    for (while_node.body) |stmt| {
        try statements.visitNode(self, stmt);
    }

    self.dedent();
    try self.emit("}");
}
