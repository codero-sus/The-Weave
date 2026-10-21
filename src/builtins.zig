//! The builtin (free-function) table shared by the compiler and the VM.
//!
//! Methods (`tasks.append(x)`, `name.upper()`) are *not* builtins: they are
//! dispatched dynamically on the receiver by `vm.callMethod`, which keeps the
//! instruction stream small and lets one name work across types.

const std = @import("std");

pub const Id = enum(u16) {
    len = 0,
    count,
    str,
    int,
    float,
    bool_,
    abs,
    min,
    max,
    sum,
    round,
    floor,
    ceil,
    range,
    sorted,
    reversed,
    print,
    log,
    now,
    random,
    rand_int,
    type_of,
    clone,
    keys,
    values,
    items,
    first,
    last,
    contains,
    join,
    enumerate,
    has,
    get,
    push,
    remove,
    insert,
    pop,
    clear,
    upper,
    lower,
    strip,
    split,
    replace,
    starts_with,
    ends_with,
    index_of,
    slice,
    set,
};

pub const Info = struct {
    id: Id,
    name: []const u8,
    min_args: u8,
    max_args: u8,
    doc: []const u8,
};

pub const table = [_]Info{
    .{ .id = .len, .name = "len", .min_args = 1, .max_args = 1, .doc = "length of a list, map or string" },
    .{ .id = .count, .name = "count", .min_args = 1, .max_args = 2, .doc = "number of items (or occurrences of a value)" },
    .{ .id = .str, .name = "str", .min_args = 1, .max_args = 1, .doc = "convert to string" },
    .{ .id = .int, .name = "int", .min_args = 1, .max_args = 1, .doc = "convert to integer" },
    .{ .id = .float, .name = "float", .min_args = 1, .max_args = 1, .doc = "convert to float" },
    .{ .id = .bool_, .name = "bool", .min_args = 1, .max_args = 1, .doc = "truthiness" },
    .{ .id = .abs, .name = "abs", .min_args = 1, .max_args = 1, .doc = "absolute value" },
    .{ .id = .min, .name = "min", .min_args = 1, .max_args = 8, .doc = "smallest value (args or list)" },
    .{ .id = .max, .name = "max", .min_args = 1, .max_args = 8, .doc = "largest value (args or list)" },
    .{ .id = .sum, .name = "sum", .min_args = 1, .max_args = 1, .doc = "sum of a numeric list" },
    .{ .id = .round, .name = "round", .min_args = 1, .max_args = 2, .doc = "round to n digits" },
    .{ .id = .floor, .name = "floor", .min_args = 1, .max_args = 1, .doc = "round down" },
    .{ .id = .ceil, .name = "ceil", .min_args = 1, .max_args = 1, .doc = "round up" },
    .{ .id = .range, .name = "range", .min_args = 1, .max_args = 3, .doc = "range(n) / range(a,b) / range(a,b,step)" },
    .{ .id = .sorted, .name = "sorted", .min_args = 1, .max_args = 1, .doc = "sorted copy of a list" },
    .{ .id = .reversed, .name = "reversed", .min_args = 1, .max_args = 1, .doc = "reversed copy of a list" },
    .{ .id = .print, .name = "print", .min_args = 0, .max_args = 8, .doc = "write to the server console" },
    .{ .id = .log, .name = "log", .min_args = 0, .max_args = 8, .doc = "alias of print" },
    .{ .id = .now, .name = "now", .min_args = 0, .max_args = 0, .doc = "unix time in milliseconds" },
    .{ .id = .random, .name = "random", .min_args = 0, .max_args = 0, .doc = "pseudo-random float in [0,1)" },
    .{ .id = .rand_int, .name = "rand_int", .min_args = 2, .max_args = 2, .doc = "pseudo-random int in [a,b]" },
    .{ .id = .type_of, .name = "type", .min_args = 1, .max_args = 1, .doc = "type name of a value" },
    .{ .id = .clone, .name = "clone", .min_args = 1, .max_args = 1, .doc = "deep copy" },
    .{ .id = .keys, .name = "keys", .min_args = 1, .max_args = 1, .doc = "map keys as a list" },
    .{ .id = .values, .name = "values", .min_args = 1, .max_args = 1, .doc = "map values as a list" },
    .{ .id = .items, .name = "items", .min_args = 1, .max_args = 1, .doc = "map entries as [key, value] pairs" },
    .{ .id = .first, .name = "first", .min_args = 1, .max_args = 1, .doc = "first item or null" },
    .{ .id = .last, .name = "last", .min_args = 1, .max_args = 1, .doc = "last item or null" },
    .{ .id = .contains, .name = "contains", .min_args = 2, .max_args = 2, .doc = "membership test" },
    .{ .id = .join, .name = "join", .min_args = 1, .max_args = 2, .doc = "join a list into a string" },
    .{ .id = .enumerate, .name = "enumerate", .min_args = 1, .max_args = 1, .doc = "list of [index, item] pairs" },
    .{ .id = .has, .name = "has", .min_args = 2, .max_args = 2, .doc = "map/list membership" },
    .{ .id = .get, .name = "get", .min_args = 2, .max_args = 3, .doc = "map/list lookup with default" },
    .{ .id = .push, .name = "push", .min_args = 2, .max_args = 2, .doc = "append to a list" },
    .{ .id = .remove, .name = "remove", .min_args = 2, .max_args = 2, .doc = "remove a value from a list or key from a map" },
    .{ .id = .insert, .name = "insert", .min_args = 3, .max_args = 3, .doc = "insert at index" },
    .{ .id = .pop, .name = "pop", .min_args = 1, .max_args = 2, .doc = "remove and return" },
    .{ .id = .clear, .name = "clear", .min_args = 1, .max_args = 1, .doc = "empty a list or map" },
    .{ .id = .upper, .name = "upper", .min_args = 1, .max_args = 1, .doc = "uppercase a string" },
    .{ .id = .lower, .name = "lower", .min_args = 1, .max_args = 1, .doc = "lowercase a string" },
    .{ .id = .strip, .name = "strip", .min_args = 1, .max_args = 1, .doc = "trim whitespace" },
    .{ .id = .split, .name = "split", .min_args = 1, .max_args = 2, .doc = "split a string into a list" },
    .{ .id = .replace, .name = "replace", .min_args = 3, .max_args = 3, .doc = "replace occurrences in a string" },
    .{ .id = .starts_with, .name = "starts_with", .min_args = 2, .max_args = 2, .doc = "string prefix test" },
    .{ .id = .ends_with, .name = "ends_with", .min_args = 2, .max_args = 2, .doc = "string suffix test" },
    .{ .id = .index_of, .name = "index_of", .min_args = 2, .max_args = 2, .doc = "position of a value (-1 when absent)" },
    .{ .id = .slice, .name = "slice", .min_args = 2, .max_args = 3, .doc = "slice a list or string" },
    .{ .id = .set, .name = "set", .min_args = 3, .max_args = 3, .doc = "set a map key or list index" },
};

pub fn byName(name: []const u8) ?Id {
    for (table) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.id;
    }
    return null;
}

pub fn info(id: Id) Info {
    for (table) |t| if (t.id == id) return t;
    return table[0];
}

pub fn isBuiltinName(name: []const u8) bool {
    return byName(name) != null;
}
