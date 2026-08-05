const std = @import("std");
const convert = @import("convert.zig");

const Allocator = std.mem.Allocator;
const Rule = convert.Rule;
const Writer = std.Io.Writer;

pub fn write(writer: *Writer, rules: []const Rule) Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };

    try json.beginArray();
    for (rules) |rule| {
        try json.beginObject();

        try json.objectField("trigger");
        try json.beginObject();
        try json.objectField("url-filter");
        try json.write(rule.url_filter);
        // WebKit matches case insensitive unless told otherwise, so key only
        // appears when filter asks for `match-case`.
        if (rule.case_sensitive) {
            try json.objectField("url-filter-is-case-sensitive");
            try json.write(true);
        }
        if (rule.types.len > 0) {
            try json.objectField("resource-type");
            try json.beginArray();
            for (rule.types) |kind| try json.write(kind.webkitName());
            try json.endArray();
        }
        if (rule.load_type) |load| {
            try json.objectField("load-type");
            try json.beginArray();
            try json.write(load.webkitName());
            try json.endArray();
        }
        if (rule.if_domain.len > 0) {
            try json.objectField("if-domain");
            try writeStrings(&json, rule.if_domain);
        }
        if (rule.unless_domain.len > 0) {
            try json.objectField("unless-domain");
            try writeStrings(&json, rule.unless_domain);
        }
        try json.endObject();

        try json.objectField("action");
        try json.beginObject();
        try json.objectField("type");
        try json.write(rule.action.webkitName());
        if (rule.action == .css_display_none) {
            try json.objectField("selector");
            try json.write(rule.selector);
        }
        try json.endObject();

        try json.endObject();
    }
    try json.endArray();
}

fn writeStrings(json: *std.json.Stringify, items: []const []const u8) Writer.Error!void {
    try json.beginArray();
    for (items) |item| try json.write(item);
    try json.endArray();
}

pub fn deduplicate(gpa: Allocator, rules: *std.ArrayList(Rule)) Allocator.Error!usize {
    var seen: std.HashMapUnmanaged(Rule, void, Context, std.hash_map.default_max_load_percentage) = .empty;
    defer seen.deinit(gpa);
    try seen.ensureTotalCapacity(gpa, @intCast(rules.items.len));

    var kept: usize = 0;
    for (rules.items) |rule| {
        if (seen.getOrPutAssumeCapacity(rule).found_existing) continue;
        rules.items[kept] = rule;
        kept += 1;
    }

    const removed = rules.items.len - kept;
    rules.shrinkRetainingCapacity(kept);
    return removed;
}

const Context = struct {
    pub fn hash(_: Context, rule: Rule) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(rule.url_filter);
        hasher.update(rule.selector);
        hasher.update(&.{
            @intFromEnum(rule.action),
            @intFromBool(rule.case_sensitive),
            if (rule.load_type) |load| @as(u8, @intFromEnum(load)) + 1 else 0,
        });
        for (rule.types) |kind| hasher.update(&.{@intFromEnum(kind)});
        hasher.update(&.{0});
        for (rule.if_domain) |domain| {
            hasher.update(domain);
            hasher.update(&.{0});
        }
        hasher.update(&.{1});
        for (rule.unless_domain) |domain| {
            hasher.update(domain);
            hasher.update(&.{0});
        }
        return hasher.final();
    }

    pub fn eql(_: Context, a: Rule, b: Rule) bool {
        return a.action == b.action and
            a.case_sensitive == b.case_sensitive and
            a.load_type == b.load_type and
            std.mem.eql(u8, a.url_filter, b.url_filter) and
            std.mem.eql(u8, a.selector, b.selector) and
            std.mem.eql(convert.ResourceType, a.types, b.types) and
            eqlStrings(a.if_domain, b.if_domain) and
            eqlStrings(a.unless_domain, b.unless_domain);
    }
};

fn eqlStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

const testing = std.testing;

fn writeToString(rules: []const Rule) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try write(&out.writer, rules);
    return try out.toOwnedSlice();
}

test "a blocking rule is a trigger and an action" {
    const text = try writeToString(&.{.{ .url_filter = "ads\\.example", .action = .block }});
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(
        \\[{"trigger":{"url-filter":"ads\\.example"},"action":{"type":"block"}}]
    , text);
}

test "the optional trigger keys only appear when they are set" {
    const text = try writeToString(&.{.{
        .url_filter = ".*",
        .case_sensitive = true,
        .types = &.{ .image, .script },
        .load_type = .third_party,
        .if_domain = &.{"*example.com"},
        .action = .block,
    }});
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(
        \\[{"trigger":{"url-filter":".*","url-filter-is-case-sensitive":true,"resource-type":["image","script"],"load-type":["third-party"],"if-domain":["*example.com"]},"action":{"type":"block"}}]
    , text);
}

test "a hiding rule carries its selector" {
    const text = try writeToString(&.{.{
        .url_filter = ".*",
        .unless_domain = &.{"*example.com"},
        .action = .css_display_none,
        .selector = ".ad-banner",
    }});
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(
        \\[{"trigger":{"url-filter":".*","unless-domain":["*example.com"]},"action":{"type":"css-display-none","selector":".ad-banner"}}]
    , text);
}

test "an empty list is still a JSON array" {
    const text = try writeToString(&.{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("[]", text);
}

test "identical rules collapse to one" {
    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(testing.allocator);
    try rules.appendSlice(testing.allocator, &.{
        .{ .url_filter = "a", .action = .block },
        .{ .url_filter = "a", .action = .block },
        .{ .url_filter = "a", .action = .ignore_previous_rules },
        .{ .url_filter = "b", .action = .block },
        .{ .url_filter = "a", .action = .block },
    });

    try testing.expectEqual(@as(usize, 2), try deduplicate(testing.allocator, &rules));
    try testing.expectEqual(@as(usize, 3), rules.items.len);
    try testing.expectEqualStrings("a", rules.items[0].url_filter);
    try testing.expectEqual(convert.Action.ignore_previous_rules, rules.items[1].action);
    try testing.expectEqualStrings("b", rules.items[2].url_filter);
}

test "rules differing only in their domains are both kept" {
    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(testing.allocator);
    try rules.appendSlice(testing.allocator, &.{
        .{ .url_filter = "a", .action = .block, .if_domain = &.{"*one.example"} },
        .{ .url_filter = "a", .action = .block, .if_domain = &.{"*two.example"} },
        .{ .url_filter = "a", .action = .block, .unless_domain = &.{"*one.example"} },
    });

    try testing.expectEqual(@as(usize, 0), try deduplicate(testing.allocator, &rules));
    try testing.expectEqual(@as(usize, 3), rules.items.len);
}
