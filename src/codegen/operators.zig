const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const expressions = @import("expressions.zig");

pub const CodegenError = codegen.CodegenError;
pub const ExprResult = codegen.ExprResult;
pub const ZigCodeGenerator = codegen.ZigCodeGenerator;

/// Helper to convert binary operator to Zig operator string
fn visitBinOpHelper(self: *ZigCodeGenerator, op: ast.Operator) []const u8 {
    _ = self;
    return switch (op) {
        .Add => "+",
        .Sub => "-",
        .Mult => "*",
        .Div => "/",
        .Mod => "%",
        .FloorDiv => "//", // Handled specially in visitBinOp
        .Pow => "**", // Handled specially in visitBinOp
        .BitAnd => "&",
        .BitOr => "|",
        .BitXor => "^",
    };
}

/// Helper to convert comparison operator to Zig operator string
fn visitCompareOp(self: *ZigCodeGenerator, op: ast.CompareOp) []const u8 {
    _ = self;
    return switch (op) {
        .Lt => "<",
        .LtEq => "<=",
        .Gt => ">",
        .GtEq => ">=",
        .Eq => "==",
        .NotEq => "!=",
        .In => "in", // Will need special handling
        .NotIn => "not in", // Will need special handling
    };
}

/// Visit binary operation node (e.g., a + b, a * b)
pub fn visitBinOp(self: *ZigCodeGenerator, binop: ast.Node.BinOp) CodegenError!ExprResult {
    const left_result = try expressions.visitExpr(self,binop.left.*);
    const right_result = try expressions.visitExpr(self,binop.right.*);

    var buf = std.ArrayList(u8){};

    // Check for string concatenation (string + string)
    if (binop.op == .Add) {
        const is_left_string = blk: {
            switch (binop.left.*) {
                .name => |name| {
                    const var_type = self.var_types.get(name.id);
                    break :blk var_type != null and std.mem.eql(u8, var_type.?, "string");
                },
                .constant => |c| {
                    break :blk c.value == .string;
                },
                else => break :blk false,
            }
        };

        const is_right_string = blk: {
            switch (binop.right.*) {
                .name => |name| {
                    const var_type = self.var_types.get(name.id);
                    break :blk var_type != null and std.mem.eql(u8, var_type.?, "string");
                },
                .constant => |c| {
                    break :blk c.value == .string;
                },
                else => break :blk false,
            }
        };

        if (is_left_string or is_right_string) {
            // String concatenation - extract nested temps to statements to prevent leaks
            const left_code = try self.extractResultToStatement(left_result);
            const right_code = try self.extractResultToStatement(right_result);

            try buf.writer(self.temp_allocator).print("runtime.PyString.concat(allocator, {s}, {s})", .{ left_code, right_code });

            return ExprResult{
                .code = try buf.toOwnedSlice(self.temp_allocator),
                .needs_try = true,
                .needs_decref = true, // Mark as needing cleanup
            };
        }
    }

    // Handle operators that need special Zig functions
    switch (binop.op) {
        .FloorDiv => {
            // Floor division: use @divFloor builtin
            try buf.writer(self.temp_allocator).print("@divFloor({s}, {s})", .{ left_result.code, right_result.code });
        },
        .Pow => {
            // Exponentiation: use std.math.pow
            try buf.writer(self.temp_allocator).print("std.math.pow(i64, {s}, {s})", .{ left_result.code, right_result.code });
        },
        else => {
            // Standard operators that map directly to Zig operators
            const op_str = visitBinOpHelper(self, binop.op);
            try buf.writer(self.temp_allocator).print("{s} {s} {s}", .{ left_result.code, op_str, right_result.code });
        },
    }

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = left_result.needs_try or right_result.needs_try,
    };
}

/// Visit unary operation node (e.g., -x, !x, +x)
pub fn visitUnaryOp(self: *ZigCodeGenerator, unaryop: ast.Node.UnaryOp) CodegenError!ExprResult {
    const operand_result = try expressions.visitExpr(self,unaryop.operand.*);

    const op_str = switch (unaryop.op) {
        .Not => "!",
        .USub => "-",
        .UAdd => "+",
    };

    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("{s}({s})", .{ op_str, operand_result.code });

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = operand_result.needs_try,
    };
}

/// Visit boolean operation node (e.g., a and b, a or b)
pub fn visitBoolOp(self: *ZigCodeGenerator, boolop: ast.Node.BoolOp) CodegenError!ExprResult {
    if (boolop.values.len < 2) {
        return error.UnsupportedExpression;
    }

    const left_result = try expressions.visitExpr(self,boolop.values[0]);
    const right_result = try expressions.visitExpr(self,boolop.values[1]);

    const op_str = switch (boolop.op) {
        .And => "and",
        .Or => "or",
    };

    var buf = std.ArrayList(u8){};
    try buf.writer(self.temp_allocator).print("({s} {s} {s})", .{ left_result.code, op_str, right_result.code });

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = left_result.needs_try or right_result.needs_try,
    };
}

/// Visit comparison node (e.g., a < b, a == b, x in list)
pub fn visitCompare(self: *ZigCodeGenerator, compare: ast.Node.Compare) CodegenError!ExprResult {
    if (compare.ops.len == 0 or compare.comparators.len == 0) {
        return error.InvalidCompare;
    }

    const left_result = try expressions.visitExpr(self,compare.left.*);
    const right_result = try expressions.visitExpr(self,compare.comparators[0]);

    const op = compare.ops[0];
    var buf = std.ArrayList(u8){};

    // Handle 'in' and 'not in' operators specially
    if (op == .In or op == .NotIn) {
        self.needs_runtime = true;

        // For primitive constants, wrap in PyObjects with proper cleanup using block expressions
        const left_code = left_result.code;
        var needs_temp_var = false;
        var create_call: []const u8 = undefined;

        if (compare.left.* == .constant) {
            const constant = compare.left.*.constant;
            switch (constant.value) {
                .int => {
                    // Int constants are raw values like "3"
                    create_call = try std.fmt.allocPrint(self.allocator, "runtime.PyInt.create(allocator, {s})", .{left_code});
                    needs_temp_var = true;
                },
                .string => {
                    // String constants already return full create call
                    create_call = left_code;
                    needs_temp_var = true;
                },
                .bool => {
                    // Bool constants are raw values like "true"
                    create_call = try std.fmt.allocPrint(self.allocator, "runtime.PyBool.create(allocator, {s})", .{left_code});
                    needs_temp_var = true;
                },
                .float => {
                    // Float constants are raw values like "3.14"
                    create_call = try std.fmt.allocPrint(self.allocator, "runtime.PyFloat.create(allocator, {s})", .{left_code});
                    needs_temp_var = true;
                },
            }
        }

        // Use labeled block for scoped temp variable with defer
        if (needs_temp_var) {
            const temp_var_name = try std.fmt.allocPrint(self.allocator, "__contains_temp_{d}", .{self.temp_var_counter});
            self.temp_var_counter += 1;

            // Generate block expression: blk: { const temp = try <create_call>; defer decref; break :blk contains(...); }
            const negation = if (op == .NotIn) "!" else "";
            try buf.writer(self.temp_allocator).print(
                "blk: {{ const {s} = try {s}; defer runtime.decref({s}, allocator); break :blk {s}runtime.contains({s}, {s}); }}",
                .{ temp_var_name, create_call, temp_var_name, negation, temp_var_name, right_result.code }
            );
        } else {
            // No temp needed - direct contains call
            const negation = if (op == .NotIn) "!" else "";
            try buf.writer(self.temp_allocator).print("{s}runtime.contains({s}, {s})", .{ negation, left_code, right_result.code });
        }
    } else {
        const op_str = visitCompareOp(self, op);

        // Unwrap PyObjects if needed
        var left_code = left_result.code;
        var right_code = right_result.code;

        // Check if left operand is a PyObject variable that needs unwrapping
        if (compare.left.* == .name) {
            const var_name = compare.left.*.name.id;
            const var_type = self.var_types.get(var_name);
            if (var_type) |vtype| {
                if (std.mem.eql(u8, vtype, "pyobject")) {
                    left_code = try std.fmt.allocPrint(self.allocator, "runtime.PyInt.getValue({s})", .{left_code});
                }
            }
        }

        // Check if right operand is a PyObject variable that needs unwrapping
        if (compare.comparators[0] == .name) {
            const var_name = compare.comparators[0].name.id;
            const var_type = self.var_types.get(var_name);
            if (var_type) |vtype| {
                if (std.mem.eql(u8, vtype, "pyobject")) {
                    right_code = try std.fmt.allocPrint(self.allocator, "runtime.PyInt.getValue({s})", .{right_code});
                }
            }
        }

        try buf.writer(self.temp_allocator).print("{s} {s} {s}", .{ left_code, op_str, right_code });
    }

    return ExprResult{
        .code = try buf.toOwnedSlice(self.temp_allocator),
        .needs_try = false,
    };
}
