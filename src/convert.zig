const std = @import("std");
const parse = @import("parse.zig");
const regex = @import("regex.zig");

const Allocator = std.mem.Allocator;
const SkipReason = parse.SkipReason;

pub const ResourceType = parse.ResourceType;

pub const Action = enum {
    block,
    css_display_none,
    ignore_previous_rules,

    pub fn webkitName(self: Action) []const u8 {
        return switch (self) {
            .block => "block",
            .css_display_none => "css-display-none",
            .ignore_previous_rules => "ignore-previous-rules",
        };
    }
};

pub const LoadType = enum {
    first_party,
    third_party,

    pub fn webkitName(self: LoadType) []const u8 {
        return switch (self) {
            .first_party => "first-party",
            .third_party => "third-party",
        };
    }
};

pub const Rule = struct {
    url_filter: []const u8,
    case_sensitive: bool = false,
    types: []const ResourceType = &.{},
    load_type: ?LoadType = null,
    if_domain: []const []const u8 = &.{},
    unless_domain: []const []const u8 = &.{},
    action: Action,
    selector: []const u8 = "",
};

pub const Converter = struct {
    gpa: Allocator,
    arena: Allocator,
    rewriter: regex.Rewriter,

    pub fn init(gpa: Allocator, arena: Allocator) Converter {
        return .{ .gpa = gpa, .arena = arena, .rewriter = .{ .gpa = gpa } };
    }

    pub fn deinit(self: *Converter) void {
        self.rewriter.deinit();
    }

    pub fn filter(
        self: *Converter,
        source: parse.Filter,
        out: *std.ArrayList(Rule),
    ) Allocator.Error!?SkipReason {
        return switch (source.kind) {
            .network => try self.networkRules(source, .block, out),
            .exception => try self.networkRules(source, .ignore_previous_rules, out),
            .cosmetic => try self.cosmeticRule(source, out),
            .comment, .unsupported => source.skip,
        };
    }

    fn networkRules(
        self: *Converter,
        source: parse.Filter,
        action: Action,
        out: *std.ArrayList(Rule),
    ) Allocator.Error!?SkipReason {
        const domains = switch (try self.domainCondition(source)) {
            .skip => |reason| return reason,
            .ok => |value| value,
        };

        const expression = try self.rewriter.fromPattern(source.pattern);
        if (!regex.isValid(expression)) return .invalid_regex;
        const url_filter = try self.arena.dupe(u8, expression);

        const rule: Rule = .{
            .url_filter = url_filter,
            .case_sensitive = source.match_case,
            .types = try self.resourceTypes(source.types),
            .load_type = if (source.third_party) |third|
                if (third) .third_party else .first_party
            else
                null,
            .if_domain = domains.include,
            .unless_domain = domains.exclude,
            .action = action,
        };
        try out.append(self.gpa, rule);

        // `^` matches separator character. WebKit takes one expression per
        // rule -> second reading gets second rule.
        if (!regex.endsWithSeparator(source.pattern)) return null;

        const anchored = try self.rewriter.fromPatternEndAnchored(source.pattern);
        if (!regex.isValid(anchored)) return null;

        var second = rule;
        second.url_filter = try self.arena.dupe(u8, anchored);
        try out.append(self.gpa, second);
        return null;
    }

    fn cosmeticRule(
        self: *Converter,
        source: parse.Filter,
        out: *std.ArrayList(Rule),
    ) Allocator.Error!?SkipReason {
        if (source.selector.len == 0) return .empty_selector;
        const domains = switch (try self.domainCondition(source)) {
            .skip => |reason| return reason,
            .ok => |value| value,
        };

        try out.append(self.gpa, .{
            // Hiding rule applies to the page rather than request, so trigger
            // matches every URL and domain lists do the work.
            .url_filter = ".*",
            .if_domain = domains.include,
            .unless_domain = domains.exclude,
            .action = .css_display_none,
            .selector = try self.arena.dupe(u8, source.selector),
        });
        return null;
    }

    const Domains = struct {
        include: []const []const u8 = &.{},
        exclude: []const []const u8 = &.{},
    };

    const Condition = union(enum) {
        ok: Domains,
        skip: SkipReason,
    };

    /// `if-domain` and `unless-domain` lists, or reason filter's domains cannot
    /// become trigger.
    fn domainCondition(self: *Converter, source: parse.Filter) Allocator.Error!Condition {
        if (source.include.len > 0 and source.exclude.len > 0) {
            return .{ .skip = .domain_intersection };
        }
        for (source.include) |domain| {
            if (isEntity(domain)) return .{ .skip = .entity_domain };
        }
        for (source.exclude) |domain| {
            if (isEntity(domain)) return .{ .skip = .entity_domain };
        }

        return .{ .ok = .{
            .include = try self.normalize(source.include) orelse return .{ .skip = .invalid_domain },
            .exclude = try self.normalize(source.exclude) orelse return .{ .skip = .invalid_domain },
        } };
    }

    /// Lowercase each domain and put `*` in front -> WebKit's "this domain and
    /// everything under it".
    /// Result is sorted so two filters naming the same domains in different
    /// order give same rule and one of them is dropped as duplicate.
    fn normalize(self: *Converter, domains: []const []const u8) Allocator.Error!?[]const []const u8 {
        if (domains.len == 0) return &.{};

        const list = try self.arena.alloc([]const u8, domains.len);
        for (domains, list) |source, *slot| {
            const trimmed = std.mem.trim(u8, source, " \t");
            if (trimmed.len == 0) return null;

            const prefixed = trimmed[0] == '*' or trimmed[0] == '.';
            const text = try self.arena.alloc(u8, if (prefixed) trimmed.len else trimmed.len + 1);
            if (!prefixed) text[0] = '*';
            const body = if (prefixed) text else text[1..];
            for (trimmed, body) |ch, *out| {
                if (!isDomainChar(ch)) return null;
                out.* = std.ascii.toLower(ch);
            }
            slot.* = text;
        }

        std.mem.sort([]const u8, list, {}, lessThan);
        return list;
    }

    /// Sorted and free of repeats, for the same reason as above.
    fn resourceTypes(self: *Converter, types: []const ResourceType) Allocator.Error![]const ResourceType {
        if (types.len == 0) return &.{};

        const list = try self.arena.alloc(ResourceType, types.len);
        @memcpy(list, types);
        std.mem.sort(ResourceType, list, {}, lessThanType);

        var count: usize = 1;
        for (list[1..]) |kind| {
            if (list[count - 1] == kind) continue;
            list[count] = kind;
            count += 1;
        }
        return list[0..count];
    }
};

/// uBlock Origin's entity syntax (e.g. `example.*`) matches name under every
/// top level domain. WebKit domain condition takes leading `*` for subdomains.
fn isEntity(domain: []const u8) bool {
    return std.mem.endsWith(u8, domain, ".*");
}

fn isDomainChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '*';
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessThanType(_: void, a: ResourceType, b: ResourceType) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

const testing = std.testing;

const Outcome = struct {
    arena: std.heap.ArenaAllocator,
    rules: std.ArrayList(Rule),
    skip: ?SkipReason,

    fn deinit(self: *Outcome) void {
        self.rules.deinit(testing.allocator);
        self.arena.deinit();
    }
};

fn convertLine(text: []const u8) !Outcome {
    var outcome: Outcome = .{
        .arena = .init(testing.allocator),
        .rules = .empty,
        .skip = null,
    };
    errdefer outcome.deinit();

    var parser: parse.Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    var converter: Converter = .init(testing.allocator, outcome.arena.allocator());
    defer converter.deinit();

    const filter = try parser.line(text);
    outcome.skip = try converter.filter(filter, &outcome.rules);
    return outcome;
}

test "a hostname filter with a separator gives two rules" {
    var outcome = try convertLine("||ads.example.com^");
    defer outcome.deinit();

    try testing.expectEqual(@as(usize, 2), outcome.rules.items.len);
    try testing.expectEqual(Action.block, outcome.rules.items[0].action);
    try testing.expectEqualStrings(
        "^[a-z-]+://([^/?#]+\\.)?ads\\.example\\.com[^%.0-9a-z_-]",
        outcome.rules.items[0].url_filter,
    );
    try testing.expectEqualStrings(
        "^[a-z-]+://([^/?#]+\\.)?ads\\.example\\.com$",
        outcome.rules.items[1].url_filter,
    );
}

test "an exception filter ignores the rules before it" {
    var outcome = try convertLine("@@||safe.example.com/ads.js");
    defer outcome.deinit();

    try testing.expectEqual(@as(usize, 1), outcome.rules.items.len);
    try testing.expectEqual(Action.ignore_previous_rules, outcome.rules.items[0].action);
}

test "options become the load type and the resource types" {
    var outcome = try convertLine("/ad.js$third-party,image,script,script");
    defer outcome.deinit();

    const rule = outcome.rules.items[0];
    try testing.expectEqual(LoadType.third_party, rule.load_type.?);
    try testing.expectEqualSlices(ResourceType, &.{ .image, .script }, rule.types);
}

test "a domain option becomes a sorted if-domain with wildcards" {
    var outcome = try convertLine("/ad.js$domain=zeta.example|alpha.example");
    defer outcome.deinit();

    const rule = outcome.rules.items[0];
    try testing.expectEqual(@as(usize, 2), rule.if_domain.len);
    try testing.expectEqualStrings("*alpha.example", rule.if_domain[0]);
    try testing.expectEqualStrings("*zeta.example", rule.if_domain[1]);
    try testing.expectEqual(@as(usize, 0), rule.unless_domain.len);
}

test "a cosmetic filter hides its selector on its domains" {
    var outcome = try convertLine("Example.COM##.ad-banner");
    defer outcome.deinit();

    const rule = outcome.rules.items[0];
    try testing.expectEqual(Action.css_display_none, rule.action);
    try testing.expectEqualStrings(".*", rule.url_filter);
    try testing.expectEqualStrings(".ad-banner", rule.selector);
    try testing.expectEqualStrings("*example.com", rule.if_domain[0]);
}

test "an excluded domain becomes unless-domain" {
    var outcome = try convertLine("~example.com##.ad-banner");
    defer outcome.deinit();

    const rule = outcome.rules.items[0];
    try testing.expectEqual(@as(usize, 0), rule.if_domain.len);
    try testing.expectEqualStrings("*example.com", rule.unless_domain[0]);
}

test "a filter needing both domain lists has no representation" {
    var outcome = try convertLine("/ad.js$domain=example.com|~sub.example.com");
    defer outcome.deinit();

    try testing.expectEqual(@as(usize, 0), outcome.rules.items.len);
    try testing.expectEqual(SkipReason.domain_intersection, outcome.skip.?);
}

test "an entity domain has no representation" {
    var outcome = try convertLine("/ad.js$domain=example.*");
    defer outcome.deinit();

    try testing.expectEqual(SkipReason.entity_domain, outcome.skip.?);
}

test "a pattern outside WebKit's subset is dropped" {
    var outcome = try convertLine("/ads|banners/");
    defer outcome.deinit();

    try testing.expectEqual(@as(usize, 0), outcome.rules.items.len);
    try testing.expectEqual(SkipReason.invalid_regex, outcome.skip.?);
}

test "a non-ASCII domain is dropped rather than passed on" {
    var outcome = try convertLine("/ad.js$domain=wérbung.example");
    defer outcome.deinit();

    try testing.expectEqual(SkipReason.invalid_domain, outcome.skip.?);
}
