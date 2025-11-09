/// Zyth Runtime Library
/// Core runtime support for compiled Python code
const std = @import("std");

/// Python object representation
pub const PyObject = struct {
    ref_count: usize,
    type_id: TypeId,
    data: *anyopaque,

    pub const TypeId = enum {
        int,
        float,
        bool,
        string,
        list,
        dict,
        none,
    };
};

/// Reference counting
pub fn incref(obj: *PyObject) void {
    obj.ref_count += 1;
}

pub fn decref(obj: *PyObject, allocator: std.mem.Allocator) void {
    obj.ref_count -= 1;
    if (obj.ref_count == 0) {
        // Free internal data based on type
        switch (obj.type_id) {
            .int => {
                const data: *PyInt = @ptrCast(@alignCast(obj.data));
                allocator.destroy(data);
            },
            .list => {
                const data: *PyList = @ptrCast(@alignCast(obj.data));
                // Decref all items
                for (data.items.items) |item| {
                    decref(item, allocator);
                }
                data.items.deinit(data.allocator);
                allocator.destroy(data);
            },
            .string => {
                const data: *PyString = @ptrCast(@alignCast(obj.data));
                allocator.free(data.data);
                allocator.destroy(data);
            },
            .dict => {
                const data: *PyDict = @ptrCast(@alignCast(obj.data));
                // Decref all values
                var it = data.map.valueIterator();
                while (it.next()) |value| {
                    decref(value.*, allocator);
                }
                data.map.deinit();
                allocator.destroy(data);
            },
            else => {},
        }
        allocator.destroy(obj);
    }
}

/// Python integer type
pub const PyInt = struct {
    value: i64,

    pub fn create(allocator: std.mem.Allocator, val: i64) !*PyObject {
        const obj = try allocator.create(PyObject);
        const int_data = try allocator.create(PyInt);
        int_data.value = val;

        obj.* = PyObject{
            .ref_count = 1,
            .type_id = .int,
            .data = int_data,
        };
        return obj;
    }

    pub fn getValue(obj: *PyObject) i64 {
        std.debug.assert(obj.type_id == .int);
        const data: *PyInt = @ptrCast(@alignCast(obj.data));
        return data.value;
    }
};

/// Python list type
pub const PyList = struct {
    items: std.ArrayList(*PyObject),
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) !*PyObject {
        const obj = try allocator.create(PyObject);
        const list_data = try allocator.create(PyList);

        // Initialize ArrayList using 0.15.x unmanaged pattern
        list_data.* = PyList{
            .items = .{}, // Empty unmanaged ArrayList
            .allocator = allocator,
        };

        obj.* = PyObject{
            .ref_count = 1,
            .type_id = .list,
            .data = list_data,
        };
        return obj;
    }

    pub fn append(obj: *PyObject, item: *PyObject) !void {
        std.debug.assert(obj.type_id == .list);
        const data: *PyList = @ptrCast(@alignCast(obj.data));
        try data.items.append(data.allocator, item);
        incref(item);
    }

    pub fn pop(obj: *PyObject, allocator: std.mem.Allocator) *PyObject {
        std.debug.assert(obj.type_id == .list);
        const data: *PyList = @ptrCast(@alignCast(obj.data));
        // pop() returns the last element and removes it
        const item = data.items.items[data.items.items.len - 1];
        _ = data.items.pop(); // Remove it from the list
        // Don't decref - we're transferring ownership to caller
        _ = allocator; // Unused but kept for consistency
        return item;
    }

    pub fn getItem(obj: *PyObject, index: usize) *PyObject {
        std.debug.assert(obj.type_id == .list);
        const data: *PyList = @ptrCast(@alignCast(obj.data));
        return data.items.items[index];
    }

    pub fn len(obj: *PyObject) usize {
        std.debug.assert(obj.type_id == .list);
        const data: *PyList = @ptrCast(@alignCast(obj.data));
        return data.items.items.len;
    }

    pub fn contains(obj: *PyObject, value: *PyObject) bool {
        std.debug.assert(obj.type_id == .list);
        const data: *PyList = @ptrCast(@alignCast(obj.data));

        // Check each item in the list
        for (data.items.items) |item| {
            // For now, only support comparing integers
            if (item.type_id == .int and value.type_id == .int) {
                const item_data: *PyInt = @ptrCast(@alignCast(item.data));
                const value_data: *PyInt = @ptrCast(@alignCast(value.data));
                if (item_data.value == value_data.value) {
                    return true;
                }
            }
            // Could add string comparison here later
        }
        return false;
    }

    pub fn slice(obj: *PyObject, allocator: std.mem.Allocator, start_opt: ?i64, end_opt: ?i64) !*PyObject {
        std.debug.assert(obj.type_id == .list);
        const data: *PyList = @ptrCast(@alignCast(obj.data));

        const list_len: i64 = @intCast(data.items.items.len);

        // Handle defaults and bounds
        var start: i64 = start_opt orelse 0;
        var end: i64 = end_opt orelse list_len;

        // Handle negative indices
        if (start < 0) start = @max(0, list_len + start);
        if (end < 0) end = @max(0, list_len + end);

        // Clamp to valid range
        start = @max(0, @min(start, list_len));
        end = @max(start, @min(end, list_len));

        // Create new list
        const new_list = try create(allocator);
        const new_data: *PyList = @ptrCast(@alignCast(new_list.data));

        // Copy elements
        const start_idx: usize = @intCast(start);
        const end_idx: usize = @intCast(end);
        var i: usize = start_idx;
        while (i < end_idx) : (i += 1) {
            const item = data.items.items[i];
            try new_data.items.append(allocator, item);
            incref(item);
        }

        return new_list;
    }
};

/// Python string type
pub const PyString = struct {
    data: []const u8,

    pub fn create(allocator: std.mem.Allocator, str: []const u8) !*PyObject {
        const obj = try allocator.create(PyObject);
        const str_data = try allocator.create(PyString);
        const owned = try allocator.dupe(u8, str);
        str_data.data = owned;

        obj.* = PyObject{
            .ref_count = 1,
            .type_id = .string,
            .data = str_data,
        };
        return obj;
    }

    pub fn getValue(obj: *PyObject) []const u8 {
        std.debug.assert(obj.type_id == .string);
        const data: *PyString = @ptrCast(@alignCast(obj.data));
        return data.data;
    }

    pub fn len(obj: *PyObject) usize {
        std.debug.assert(obj.type_id == .string);
        const data: *PyString = @ptrCast(@alignCast(obj.data));
        return data.data.len;
    }

    pub fn concat(allocator: std.mem.Allocator, a: *PyObject, b: *PyObject) !*PyObject {
        std.debug.assert(a.type_id == .string);
        std.debug.assert(b.type_id == .string);
        const a_data: *PyString = @ptrCast(@alignCast(a.data));
        const b_data: *PyString = @ptrCast(@alignCast(b.data));

        const result = try allocator.alloc(u8, a_data.data.len + b_data.data.len);
        @memcpy(result[0..a_data.data.len], a_data.data);
        @memcpy(result[a_data.data.len..], b_data.data);

        const obj = try allocator.create(PyObject);
        const str_data = try allocator.create(PyString);
        str_data.data = result;

        obj.* = PyObject{
            .ref_count = 1,
            .type_id = .string,
            .data = str_data,
        };
        return obj;
    }

    pub fn upper(allocator: std.mem.Allocator, obj: *PyObject) !*PyObject {
        std.debug.assert(obj.type_id == .string);
        const data: *PyString = @ptrCast(@alignCast(obj.data));

        const result = try allocator.alloc(u8, data.data.len);
        for (data.data, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }

        const new_obj = try allocator.create(PyObject);
        const str_data = try allocator.create(PyString);
        str_data.data = result;

        new_obj.* = PyObject{
            .ref_count = 1,
            .type_id = .string,
            .data = str_data,
        };
        return new_obj;
    }

    pub fn lower(allocator: std.mem.Allocator, obj: *PyObject) !*PyObject {
        std.debug.assert(obj.type_id == .string);
        const data: *PyString = @ptrCast(@alignCast(obj.data));

        const result = try allocator.alloc(u8, data.data.len);
        for (data.data, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }

        const new_obj = try allocator.create(PyObject);
        const str_data = try allocator.create(PyString);
        str_data.data = result;

        new_obj.* = PyObject{
            .ref_count = 1,
            .type_id = .string,
            .data = str_data,
        };
        return new_obj;
    }

    pub fn contains(obj: *PyObject, substring: *PyObject) bool {
        std.debug.assert(obj.type_id == .string);
        std.debug.assert(substring.type_id == .string);
        const haystack_data: *PyString = @ptrCast(@alignCast(obj.data));
        const needle_data: *PyString = @ptrCast(@alignCast(substring.data));

        const haystack = haystack_data.data;
        const needle = needle_data.data;

        // Empty string is always contained
        if (needle.len == 0) return true;

        // Needle longer than haystack
        if (needle.len > haystack.len) return false;

        // Search for substring
        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            if (std.mem.eql(u8, haystack[i..i + needle.len], needle)) {
                return true;
            }
        }
        return false;
    }

    pub fn slice(obj: *PyObject, allocator: std.mem.Allocator, start_opt: ?i64, end_opt: ?i64) !*PyObject {
        std.debug.assert(obj.type_id == .string);
        const data: *PyString = @ptrCast(@alignCast(obj.data));

        const str_len: i64 = @intCast(data.data.len);

        // Handle defaults and bounds
        var start: i64 = start_opt orelse 0;
        var end: i64 = end_opt orelse str_len;

        // Handle negative indices
        if (start < 0) start = @max(0, str_len + start);
        if (end < 0) end = @max(0, str_len + end);

        // Clamp to valid range
        start = @max(0, @min(start, str_len));
        end = @max(start, @min(end, str_len));

        // Extract substring
        const start_idx: usize = @intCast(start);
        const end_idx: usize = @intCast(end);
        const substring = data.data[start_idx..end_idx];

        // Create new string
        return try create(allocator, substring);
    }

    pub fn split(allocator: std.mem.Allocator, obj: *PyObject, separator: *PyObject) !*PyObject {
        std.debug.assert(obj.type_id == .string);
        std.debug.assert(separator.type_id == .string);
        const data: *PyString = @ptrCast(@alignCast(obj.data));
        const sep_data: *PyString = @ptrCast(@alignCast(separator.data));

        const str = data.data;
        const sep = sep_data.data;

        // Create result list
        const result = try PyList.create(allocator);

        // Handle empty separator (split into chars)
        if (sep.len == 0) {
            for (str) |c| {
                const char_str = try allocator.alloc(u8, 1);
                char_str[0] = c;
                const char_obj = try create(allocator, char_str);
                try PyList.append(result, char_obj);
            }
            return result;
        }

        // Split by separator
        var start: usize = 0;
        var i: usize = 0;
        while (i <= str.len - sep.len) {
            if (std.mem.eql(u8, str[i..i + sep.len], sep)) {
                // Found separator - add substring
                const part = str[start..i];
                const part_obj = try create(allocator, part);
                try PyList.append(result, part_obj);
                i += sep.len;
                start = i;
            } else {
                i += 1;
            }
        }

        // Add final part
        const final_part = str[start..];
        const final_obj = try create(allocator, final_part);
        try PyList.append(result, final_obj);

        return result;
    }

    pub fn strip(allocator: std.mem.Allocator, obj: *PyObject) !*PyObject {
        std.debug.assert(obj.type_id == .string);
        const data: *PyString = @ptrCast(@alignCast(obj.data));
        const str = data.data;

        // Find first non-whitespace
        var start: usize = 0;
        while (start < str.len and std.ascii.isWhitespace(str[start])) : (start += 1) {}

        // Find last non-whitespace
        var end: usize = str.len;
        while (end > start and std.ascii.isWhitespace(str[end - 1])) : (end -= 1) {}

        // Create stripped string
        const stripped = str[start..end];
        return try create(allocator, stripped);
    }

    pub fn replace(allocator: std.mem.Allocator, obj: *PyObject, old: *PyObject, new: *PyObject) !*PyObject {
        std.debug.assert(obj.type_id == .string);
        std.debug.assert(old.type_id == .string);
        std.debug.assert(new.type_id == .string);
        const data: *PyString = @ptrCast(@alignCast(obj.data));
        const old_data: *PyString = @ptrCast(@alignCast(old.data));
        const new_data: *PyString = @ptrCast(@alignCast(new.data));

        const str = data.data;
        const old_str = old_data.data;
        const new_str = new_data.data;

        // Count occurrences to allocate result
        var count: usize = 0;
        var i: usize = 0;
        while (i <= str.len - old_str.len) {
            if (std.mem.eql(u8, str[i..i + old_str.len], old_str)) {
                count += 1;
                i += old_str.len;
            } else {
                i += 1;
            }
        }

        // If no replacements, return copy of original
        if (count == 0) {
            return try create(allocator, str);
        }

        // Calculate result size and allocate
        const result_len = str.len - (count * old_str.len) + (count * new_str.len);
        const result = try allocator.alloc(u8, result_len);

        // Build result string
        var src_idx: usize = 0;
        var dst_idx: usize = 0;
        while (src_idx < str.len) {
            if (src_idx <= str.len - old_str.len and std.mem.eql(u8, str[src_idx..src_idx + old_str.len], old_str)) {
                // Copy replacement
                @memcpy(result[dst_idx..dst_idx + new_str.len], new_str);
                src_idx += old_str.len;
                dst_idx += new_str.len;
            } else {
                // Copy original char
                result[dst_idx] = str[src_idx];
                src_idx += 1;
                dst_idx += 1;
            }
        }

        return try create(allocator, result);
    }
};

/// Python dict type (simplified - using StringHashMap)
pub const PyDict = struct {
    map: std.StringHashMap(*PyObject),

    pub fn create(allocator: std.mem.Allocator) !*PyObject {
        const obj = try allocator.create(PyObject);
        const dict_data = try allocator.create(PyDict);
        dict_data.map = std.StringHashMap(*PyObject).init(allocator);

        obj.* = PyObject{
            .ref_count = 1,
            .type_id = .dict,
            .data = dict_data,
        };
        return obj;
    }

    pub fn set(obj: *PyObject, key: []const u8, value: *PyObject) !void {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        try data.map.put(key, value);
        incref(value);
    }

    pub fn get(obj: *PyObject, key: []const u8) ?*PyObject {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        return data.map.get(key);
    }

    pub fn contains(obj: *PyObject, key: []const u8) bool {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        return data.map.contains(key);
    }

    pub fn len(obj: *PyObject) usize {
        std.debug.assert(obj.type_id == .dict);
        const data: *PyDict = @ptrCast(@alignCast(obj.data));
        return data.map.count();
    }
};

// Tests
test "PyInt creation and retrieval" {
    const allocator = std.testing.allocator;
    const obj = try PyInt.create(allocator, 42);
    defer decref(obj, allocator);

    try std.testing.expectEqual(@as(i64, 42), PyInt.getValue(obj));
    try std.testing.expectEqual(@as(usize, 1), obj.ref_count);
}

test "PyList append and retrieval" {
    const allocator = std.testing.allocator;
    const list = try PyList.create(allocator);
    defer decref(list, allocator);

    const item1 = try PyInt.create(allocator, 10);
    const item2 = try PyInt.create(allocator, 20);

    try PyList.append(list, item1);
    try PyList.append(list, item2);

    // Transfer ownership to list (decref our references)
    decref(item1, allocator);
    decref(item2, allocator);

    try std.testing.expectEqual(@as(usize, 2), PyList.len(list));
    try std.testing.expectEqual(@as(i64, 10), PyInt.getValue(PyList.getItem(list, 0)));
    try std.testing.expectEqual(@as(i64, 20), PyInt.getValue(PyList.getItem(list, 1)));
}

test "PyString creation" {
    const allocator = std.testing.allocator;
    const obj = try PyString.create(allocator, "hello");
    defer decref(obj, allocator);

    const value = PyString.getValue(obj);
    try std.testing.expectEqualStrings("hello", value);
}

test "PyDict set and get" {
    const allocator = std.testing.allocator;
    const dict = try PyDict.create(allocator);
    defer decref(dict, allocator);

    const value = try PyInt.create(allocator, 100);
    try PyDict.set(dict, "key", value);

    // Transfer ownership to dict
    decref(value, allocator);

    const retrieved = PyDict.get(dict, "key");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i64, 100), PyInt.getValue(retrieved.?));
}

test "reference counting" {
    const allocator = std.testing.allocator;
    const obj = try PyInt.create(allocator, 42);

    try std.testing.expectEqual(@as(usize, 1), obj.ref_count);

    incref(obj);
    try std.testing.expectEqual(@as(usize, 2), obj.ref_count);

    decref(obj, allocator);
    try std.testing.expectEqual(@as(usize, 1), obj.ref_count);

    decref(obj, allocator);
    // Object should be destroyed here
}
