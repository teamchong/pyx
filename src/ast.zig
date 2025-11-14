const std = @import("std");

/// AST node types matching Python's ast module
pub const Node = union(enum) {
    module: Module,
    assign: Assign,
    binop: BinOp,
    unaryop: UnaryOp,
    compare: Compare,
    boolop: BoolOp,
    call: Call,
    name: Name,
    constant: Constant,
    if_stmt: If,
    for_stmt: For,
    while_stmt: While,
    function_def: FunctionDef,
    class_def: ClassDef,
    return_stmt: Return,
    list: List,
    listcomp: ListComp,
    dict: Dict,
    tuple: Tuple,
    subscript: Subscript,
    attribute: Attribute,
    expr_stmt: ExprStmt,
    await_expr: AwaitExpr,
    import_stmt: Import,
    import_from: ImportFrom,

    pub const Module = struct {
        body: []Node,
    };

    pub const Assign = struct {
        targets: []Node,
        value: *Node,
    };

    pub const BinOp = struct {
        left: *Node,
        op: Operator,
        right: *Node,
    };

    pub const UnaryOp = struct {
        op: UnaryOperator,
        operand: *Node,
    };

    pub const Call = struct {
        func: *Node,
        args: []Node,
    };

    pub const Name = struct {
        id: []const u8,
    };

    pub const Constant = struct {
        value: Value,
    };

    pub const If = struct {
        condition: *Node,
        body: []Node,
        else_body: []Node,
    };

    pub const For = struct {
        target: *Node,
        iter: *Node,
        body: []Node,
    };

    pub const While = struct {
        condition: *Node,
        body: []Node,
    };

    pub const FunctionDef = struct {
        name: []const u8,
        args: []Arg,
        body: []Node,
        is_async: bool,
    };

    pub const ClassDef = struct {
        name: []const u8,
        body: []Node,
    };

    pub const Return = struct {
        value: ?*Node,
    };

    pub const Compare = struct {
        left: *Node,
        ops: []CompareOp,
        comparators: []Node,
    };

    pub const BoolOp = struct {
        op: BoolOperator,
        values: []Node,
    };

    pub const List = struct {
        elts: []Node,
    };

    pub const ListComp = struct {
        elt: *Node, // Expression to evaluate for each element
        target: *Node, // Loop variable (e.g., 'x' in 'for x in items')
        iter: *Node, // Iterable (e.g., 'items')
        ifs: []Node, // Optional filter conditions
    };

    pub const Dict = struct {
        keys: []Node,
        values: []Node,
    };

    pub const Tuple = struct {
        elts: []Node,
    };

    pub const Subscript = struct {
        value: *Node,
        slice: Slice,
    };

    pub const Slice = union(enum) {
        index: *Node, // items[0]
        slice: SliceRange, // items[1:3]
    };

    pub const SliceRange = struct {
        lower: ?*Node, // start (null = from beginning)
        upper: ?*Node, // end (null = to end)
        step: ?*Node, // step (null = 1)
    };

    pub const Attribute = struct {
        value: *Node,
        attr: []const u8,
    };

    pub const ExprStmt = struct {
        value: *Node,
    };

    pub const AwaitExpr = struct {
        value: *Node,
    };

    /// Import statement: import numpy as np
    pub const Import = struct {
        module: []const u8, // "numpy"
        asname: ?[]const u8, // "np" or null
    };

    /// From-import statement: from numpy import array, zeros
    pub const ImportFrom = struct {
        module: []const u8, // "numpy"
        names: [][]const u8, // ["array", "zeros"]
        asnames: []?[]const u8, // [null, null] or ["arr", null]
    };

    /// Recursively free all allocations in the AST
    pub fn deinit(self: *const Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .module => |m| {
                for (m.body) |*node| node.deinit(allocator);
                allocator.free(m.body);
            },
            .assign => |a| {
                for (a.targets) |*t| t.deinit(allocator);
                allocator.free(a.targets);
                a.value.deinit(allocator);
                allocator.destroy(a.value);
            },
            .binop => |b| {
                b.left.deinit(allocator);
                allocator.destroy(b.left);
                b.right.deinit(allocator);
                allocator.destroy(b.right);
            },
            .unaryop => |u| {
                u.operand.deinit(allocator);
                allocator.destroy(u.operand);
            },
            .compare => |c| {
                c.left.deinit(allocator);
                allocator.destroy(c.left);
                allocator.free(c.ops);
                for (c.comparators) |*comp| comp.deinit(allocator);
                allocator.free(c.comparators);
            },
            .boolop => |b| {
                for (b.values) |*v| v.deinit(allocator);
                allocator.free(b.values);
            },
            .call => |c| {
                c.func.deinit(allocator);
                allocator.destroy(c.func);
                for (c.args) |*a| a.deinit(allocator);
                allocator.free(c.args);
            },
            .if_stmt => |i| {
                i.condition.deinit(allocator);
                allocator.destroy(i.condition);
                for (i.body) |*n| n.deinit(allocator);
                allocator.free(i.body);
                for (i.else_body) |*n| n.deinit(allocator);
                allocator.free(i.else_body);
            },
            .for_stmt => |f| {
                f.target.deinit(allocator);
                allocator.destroy(f.target);
                f.iter.deinit(allocator);
                allocator.destroy(f.iter);
                for (f.body) |*n| n.deinit(allocator);
                allocator.free(f.body);
            },
            .while_stmt => |w| {
                w.condition.deinit(allocator);
                allocator.destroy(w.condition);
                for (w.body) |*n| n.deinit(allocator);
                allocator.free(w.body);
            },
            .function_def => |f| {
                allocator.free(f.args);
                for (f.body) |*n| n.deinit(allocator);
                allocator.free(f.body);
            },
            .class_def => |c| {
                for (c.body) |*n| n.deinit(allocator);
                allocator.free(c.body);
            },
            .return_stmt => |r| {
                if (r.value) |v| {
                    v.deinit(allocator);
                    allocator.destroy(v);
                }
            },
            .list => |l| {
                for (l.elts) |*e| e.deinit(allocator);
                allocator.free(l.elts);
            },
            .listcomp => |lc| {
                lc.elt.deinit(allocator);
                allocator.destroy(lc.elt);
                lc.target.deinit(allocator);
                allocator.destroy(lc.target);
                lc.iter.deinit(allocator);
                allocator.destroy(lc.iter);
                for (lc.ifs) |*f| f.deinit(allocator);
                allocator.free(lc.ifs);
            },
            .dict => |d| {
                for (d.keys) |*k| k.deinit(allocator);
                allocator.free(d.keys);
                for (d.values) |*v| v.deinit(allocator);
                allocator.free(d.values);
            },
            .tuple => |t| {
                for (t.elts) |*e| e.deinit(allocator);
                allocator.free(t.elts);
            },
            .subscript => |s| {
                s.value.deinit(allocator);
                allocator.destroy(s.value);
                switch (s.slice) {
                    .index => |idx| {
                        idx.deinit(allocator);
                        allocator.destroy(idx);
                    },
                    .slice => |sl| {
                        if (sl.lower) |l| {
                            l.deinit(allocator);
                            allocator.destroy(l);
                        }
                        if (sl.upper) |u| {
                            u.deinit(allocator);
                            allocator.destroy(u);
                        }
                        if (sl.step) |st| {
                            st.deinit(allocator);
                            allocator.destroy(st);
                        }
                    },
                }
            },
            .attribute => |a| {
                a.value.deinit(allocator);
                allocator.destroy(a.value);
            },
            .expr_stmt => |e| {
                e.value.deinit(allocator);
                allocator.destroy(e.value);
            },
            .await_expr => |a| {
                a.value.deinit(allocator);
                allocator.destroy(a.value);
            },
            .import_stmt => |i| {
                // Strings are owned by parser arena, no need to free
                _ = i;
            },
            .import_from => |i| {
                allocator.free(i.names);
                allocator.free(i.asnames);
            },
            // Leaf nodes need no cleanup
            .name, .constant => {},
        }
    }
};

pub const Operator = enum {
    Add,
    Sub,
    Mult,
    Div,
    FloorDiv,
    Mod,
    Pow,
    BitAnd,
    BitOr,
    BitXor,
};

pub const CompareOp = enum {
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    In,
    NotIn,
};

pub const BoolOperator = enum {
    And,
    Or,
};

pub const UnaryOperator = enum {
    Not,
    UAdd, // Unary plus (+x)
    USub, // Unary minus (-x)
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
};

pub const Arg = struct {
    name: []const u8,
    type_annotation: ?[]const u8,
};

/// Parse JSON AST from Python's ast.dump()
pub fn parseFromJson(allocator: std.mem.Allocator, json_str: []const u8) !Node {
    // TODO: Implement JSON → AST parsing
    // For now, this is a stub that will be implemented in Phase 1
    _ = allocator;
    _ = json_str;
    return error.NotImplemented;
}
