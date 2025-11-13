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

    // Handle operators that need special Zig functions
    switch (binop.op) {
        .FloorDiv => {
            // Floor division: use @divFloor builtin
            try buf.writer(self.allocator).print("@divFloor({s}, {s})", .{ left_result.code, right_result.code });
        },
        .Pow => {
            // Exponentiation: use std.math.pow
            try buf.writer(self.allocator).print("std.math.pow(i64, {s}, {s})", .{ left_result.code, right_result.code });
        },
        else => {
            // Standard operators that map directly to Zig operators
            const op_str = visitBinOpHelper(self, binop.op);
            try buf.writer(self.allocator).print("{s} {s} {s}", .{ left_result.code, op_str, right_result.code });
        },
    }

    return ExprResult{
        .code = try buf.toOwnedSlice(self.allocator),
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
    try buf.writer(self.allocator).print("{s}({s})", .{ op_str, operand_result.code });

    return ExprResult{
        .code = try buf.toOwnedSlice(self.allocator),
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
    try buf.writer(self.allocator).print("({s} {s} {s})", .{ left_result.code, op_str, right_result.code });

    return ExprResult{
        .code = try buf.toOwnedSlice(self.allocator),
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

        // Wrap left operand if it's a primitive constant
        var left_code = left_result.code;
        if (compare.left.* == .constant) {
            const constant = compare.left.*.constant;
            switch (constant.value) {
                .int => {
                    left_code = try std.fmt.allocPrint(self.allocator, "try runtime.PyInt.create(allocator, {s})", .{left_result.code});
                },
                .string => {
                    // Strings are already wrapped by visitConstant
                },
                .bool => {
                    left_code = try std.fmt.allocPrint(self.allocator, "try runtime.PyBool.create(allocator, {s})", .{left_result.code});
                },
                .float => {
                    left_code = try std.fmt.allocPrint(self.allocator, "try runtime.PyFloat.create(allocator, {s})", .{left_result.code});
                },
            }
        }

        if (op == .In) {
            try buf.writer(self.allocator).print("runtime.contains({s}, {s})", .{ left_code, right_result.code });
        } else {
            try buf.writer(self.allocator).print("!runtime.contains({s}, {s})", .{ left_code, right_result.code });
        }
    } else {
        const op_str = visitCompareOp(self, op);
        try buf.writer(self.allocator).print("{s} {s} {s}", .{ left_result.code, op_str, right_result.code });
    }

    return ExprResult{
        .code = try buf.toOwnedSlice(self.allocator),
        .needs_try = false,
    };
}
