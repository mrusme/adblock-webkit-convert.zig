const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    comment,
    network,
    exception,
    cosmetic,
    unsupported,
};

pub const SkipReason = enum {
    scriptlet,
    html_filter,
    procedural,
    cosmetic_exception,
    hosts_entry,
    unsupported_option,
    empty_selector,
    invalid_regex,
    domain_intersection,
    entity_domain,
    invalid_domain,

    pub fn text(self: SkipReason) []const u8 {
        return switch (self) {
            .scriptlet => "scriptlet injection",
            .html_filter => "HTML filtering",
            .procedural => "procedural selector",
            .cosmetic_exception => "cosmetic exception",
            .hosts_entry => "hosts file entry",
            .unsupported_option => "unsupported option",
            .empty_selector => "empty selector",
            .invalid_regex => "pattern outside WebKit's regex subset",
            .domain_intersection => "both included and excluded domains",
            .entity_domain => "entity domain",
            .invalid_domain => "domain WebKit cannot match",
        };
    }
};

pub const ResourceType = enum {
    document,
    top_document,
    child_document,
    image,
    style_sheet,
    script,
    font,
    raw,
    fetch,
    websocket,
    other,
    svg_document,
    media,
    popup,
    ping,
    csp_report,

    pub fn webkitName(self: ResourceType) []const u8 {
        return switch (self) {
            .document => "document",
            .top_document => "top-document",
            .child_document => "child-document",
            .image => "image",
            .style_sheet => "style-sheet",
            .script => "script",
            .font => "font",
            .raw => "raw",
            .fetch => "fetch",
            .websocket => "websocket",
            .other => "other",
            .svg_document => "svg-document",
            .media => "media",
            .popup => "popup",
            .ping => "ping",
            .csp_report => "csp-report",
        };
    }
};

pub const Filter = struct {
    kind: Kind,
    skip: ?SkipReason = null,
    pattern: []const u8 = "",
    selector: []const u8 = "",
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    types: []const ResourceType = &.{},
    third_party: ?bool = null,
    match_case: bool = false,
    important: bool = false,
};

pub const Parser = struct {
    gpa: Allocator,
    include: std.ArrayList([]const u8) = .empty,
    exclude: std.ArrayList([]const u8) = .empty,
    types: std.ArrayList(ResourceType) = .empty,

    pub fn deinit(self: *Parser) void {
        self.include.deinit(self.gpa);
        self.exclude.deinit(self.gpa);
        self.types.deinit(self.gpa);
    }

    pub fn line(self: *Parser, text: []const u8) Allocator.Error!Filter {
        self.include.clearRetainingCapacity();
        self.exclude.clearRetainingCapacity();
        self.types.clearRetainingCapacity();

        const trimmed = std.mem.trim(u8, text, " \t\r\n");

        if (trimmed.len == 0 or isComment(trimmed)) return .{ .kind = .comment };

        if (isHostsEntry(trimmed)) return skipped(.hosts_entry);

        if (contains(trimmed, "##+js(") or contains(trimmed, "#@#+js(")) return skipped(.scriptlet);

        if (contains(trimmed, "##^") or contains(trimmed, "#@#^")) return skipped(.html_filter);

        if (isProcedural(trimmed)) return skipped(.procedural);

        if (std.mem.indexOf(u8, trimmed, "#@#") != null) return skipped(.cosmetic_exception);

        if (std.mem.indexOf(u8, trimmed, "##")) |at| return try self.cosmetic(trimmed, at);

        if (std.mem.startsWith(u8, trimmed, "@@")) return try self.network(trimmed[2..], .exception);

        return try self.network(trimmed, .network);
    }

    fn cosmetic(self: *Parser, text: []const u8, at: usize) Allocator.Error!Filter {
        const selector = text[at + 2 ..];
        if (selector.len == 0) return skipped(.empty_selector);

        if (at > 0) try self.splitDomains(text[0..at], ',');

        return .{
            .kind = .cosmetic,
            .selector = selector,
            .include = self.include.items,
            .exclude = self.exclude.items,
        };
    }

    fn network(self: *Parser, text: []const u8, kind: Kind) Allocator.Error!Filter {
        var filter: Filter = .{ .kind = kind, .pattern = text };

        if (optionsStart(text)) |at| {
            filter.pattern = text[0..at];
            if (!try self.options(text[at + 1 ..], &filter)) return skipped(.unsupported_option);
        }

        filter.include = self.include.items;
        filter.exclude = self.exclude.items;
        filter.types = self.types.items;
        return filter;
    }

    fn options(self: *Parser, text: []const u8, filter: *Filter) Allocator.Error!bool {
        if (hasUnsupportedOption(text)) return false;

        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |raw| {
            const part = std.mem.trim(u8, raw, " \t");
            if (part.len == 0) continue;

            if (std.mem.eql(u8, part, "all")) continue;

            if (std.mem.eql(u8, part, "third-party") or std.mem.eql(u8, part, "3p")) {
                filter.third_party = true;
                continue;
            }
            if (std.mem.eql(u8, part, "~third-party") or std.mem.eql(u8, part, "~3p") or
                std.mem.eql(u8, part, "first-party") or std.mem.eql(u8, part, "1p"))
            {
                filter.third_party = false;
                continue;
            }
            if (std.mem.eql(u8, part, "match-case")) {
                filter.match_case = true;
                continue;
            }
            if (std.mem.eql(u8, part, "important")) {
                filter.important = true;
                continue;
            }
            if (std.mem.startsWith(u8, part, "domain=")) {
                try self.splitDomains(part["domain=".len..], '|');
                continue;
            }
            if (std.mem.startsWith(u8, part, "from=")) {
                try self.splitDomains(part["from=".len..], '|');
                continue;
            }

            if (std.mem.startsWith(u8, part, "~")) return false;

            if (resourceType(part)) |kind| {
                try self.types.append(self.gpa, kind);
                continue;
            }

            return false;
        }

        return true;
    }

    fn splitDomains(self: *Parser, text: []const u8, separator: u8) Allocator.Error!void {
        var parts = std.mem.splitScalar(u8, text, separator);
        while (parts.next()) |raw| {
            const domain = std.mem.trim(u8, raw, " \t");
            if (domain.len == 0) continue;
            if (domain[0] == '~') {
                if (domain.len > 1) try self.exclude.append(self.gpa, domain[1..]);
                continue;
            }
            try self.include.append(self.gpa, domain);
        }
    }
};

fn skipped(reason: SkipReason) Filter {
    return .{ .kind = .unsupported, .skip = reason };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn isComment(text: []const u8) bool {
    if (text[0] == '!' or text[0] == '[') return true;
    return text[0] == '#' and
        !std.mem.startsWith(u8, text, "##") and
        !std.mem.startsWith(u8, text, "#@#");
}

fn isProcedural(text: []const u8) bool {
    const forms = [_][]const u8{
        ":has(",          ":has-text(",         ":xpath(",           ":matches-css(",
        ":matches-attr(", ":matches-path(",     ":min-text-length(", ":not(",
        ":upward(",       ":remove(",           ":style(",           ":others(",
        ":watch-attr(",   ":matches-property(",
    };
    for (forms) |form| {
        if (contains(text, form)) return true;
    }
    return false;
}

fn isHostsEntry(text: []const u8) bool {
    var fields = std.mem.tokenizeAny(u8, text, " \t");
    const first = fields.next() orelse return false;
    if (!isAddress(first)) return false;

    while (fields.next()) |field| {
        if (field[0] == '#') return false;
        return true;
    }
    return false;
}

fn isAddress(text: []const u8) bool {
    if (text.len == 0) return false;

    if (contains(text, ":")) {
        for (text) |ch| {
            if (ch != ':' and !std.ascii.isHex(ch)) return false;
        }
        return true;
    }

    var labels = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 3) return false;
        for (label) |ch| {
            if (!std.ascii.isDigit(ch)) return false;
        }
        count += 1;
    }
    return count == 4;
}

fn optionsStart(text: []const u8) ?usize {
    const at = std.mem.lastIndexOfScalar(u8, text, '$') orelse return null;
    if (at > 0 and text[at - 1] == '\\') return null;
    if (at + 1 < text.len and text[at + 1] == '/') return null;
    return at;
}

fn hasUnsupportedOption(text: []const u8) bool {
    const forms = [_][]const u8{
        "redirect=",    "redirect-rule=", "csp=",       "removeparam=",
        "replace=",     "header=",        "method=",    "to=",
        "permissions=", "uritransform=",  "denyallow=",
        // Regular expression as a domain value unsupported by WebKit
        // `if-domain`, slashes break comma split above.
        "domain=/",
        "from=/",
    };
    for (forms) |form| {
        if (contains(text, form)) return true;
    }
    return false;
}

fn resourceType(name: []const u8) ?ResourceType {
    const table = .{
        .{ "script", ResourceType.script },
        .{ "image", ResourceType.image },
        .{ "img", ResourceType.image },
        .{ "stylesheet", ResourceType.style_sheet },
        .{ "css", ResourceType.style_sheet },
        .{ "font", ResourceType.font },
        .{ "media", ResourceType.media },
        .{ "xmlhttprequest", ResourceType.fetch },
        .{ "xhr", ResourceType.fetch },
        .{ "subdocument", ResourceType.child_document },
        .{ "frame", ResourceType.child_document },
        .{ "ping", ResourceType.ping },
        .{ "popup", ResourceType.popup },
        .{ "other", ResourceType.other },
        .{ "websocket", ResourceType.websocket },
        .{ "document", ResourceType.top_document },
        .{ "doc", ResourceType.top_document },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

const testing = std.testing;

fn parseOne(parser: *Parser, text: []const u8) !Filter {
    return try parser.line(text);
}

test "comments and headers are not filters" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    try testing.expectEqual(Kind.comment, (try parseOne(&parser, "! EasyList")).kind);
    try testing.expectEqual(Kind.comment, (try parseOne(&parser, "[Adblock Plus 2.0]")).kind);
    try testing.expectEqual(Kind.comment, (try parseOne(&parser, "# a hosts comment")).kind);
    try testing.expectEqual(Kind.comment, (try parseOne(&parser, "   ")).kind);
}

test "a plain network filter keeps its pattern" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    const filter = try parseOne(&parser, "||ads.example.com^");
    try testing.expectEqual(Kind.network, filter.kind);
    try testing.expectEqualStrings("||ads.example.com^", filter.pattern);
    try testing.expect(filter.third_party == null);
}

test "an exception filter drops its at signs" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    const filter = try parseOne(&parser, "@@||safe.example.com^");
    try testing.expectEqual(Kind.exception, filter.kind);
    try testing.expectEqualStrings("||safe.example.com^", filter.pattern);
}

test "options set the party, the case and the resource types" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    const filter = try parseOne(&parser, "/ad.js$third-party,script,image,match-case");
    try testing.expectEqualStrings("/ad.js", filter.pattern);
    try testing.expectEqual(true, filter.third_party.?);
    try testing.expect(filter.match_case);
    try testing.expectEqualSlices(ResourceType, &.{ .script, .image }, filter.types);
}

test "first party is third party turned off" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    try testing.expectEqual(false, (try parseOne(&parser, "/ad.js$~third-party")).third_party.?);
    try testing.expectEqual(false, (try parseOne(&parser, "/ad.js$1p")).third_party.?);
}

test "a domain option splits into included and excluded" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    const filter = try parseOne(&parser, "/ad.js$domain=example.com|foo.net|~bar.org");
    try testing.expectEqual(@as(usize, 2), filter.include.len);
    try testing.expectEqualStrings("example.com", filter.include[0]);
    try testing.expectEqualStrings("foo.net", filter.include[1]);
    try testing.expectEqual(@as(usize, 1), filter.exclude.len);
    try testing.expectEqualStrings("bar.org", filter.exclude[0]);
}

test "an unknown or negated option drops the filter" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    try testing.expectEqual(SkipReason.unsupported_option, (try parseOne(&parser, "/ad.js$redirect=noop.js")).skip.?);
    try testing.expectEqual(SkipReason.unsupported_option, (try parseOne(&parser, "/ad.js$csp=script-src")).skip.?);
    try testing.expectEqual(SkipReason.unsupported_option, (try parseOne(&parser, "/ad.js$~script")).skip.?);
    try testing.expectEqual(SkipReason.unsupported_option, (try parseOne(&parser, "/ad.js$webrtc")).skip.?);
    try testing.expectEqual(SkipReason.unsupported_option, (try parseOne(&parser, "/ad.js$domain=/ads/")).skip.?);
}

test "a cosmetic filter keeps its selector and domains" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    const filter = try parseOne(&parser, "example.com,~sub.example.com##.ad-banner");
    try testing.expectEqual(Kind.cosmetic, filter.kind);
    try testing.expectEqualStrings(".ad-banner", filter.selector);
    try testing.expectEqualStrings("example.com", filter.include[0]);
    try testing.expectEqualStrings("sub.example.com", filter.exclude[0]);
}

test "a global cosmetic filter has no domains" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    const filter = try parseOne(&parser, "##.ad-banner");
    try testing.expectEqual(Kind.cosmetic, filter.kind);
    try testing.expectEqual(@as(usize, 0), filter.include.len);
}

test "the syntaxes with no WebKit counterpart are reported by name" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    try testing.expectEqual(SkipReason.scriptlet, (try parseOne(&parser, "example.com##+js(nano-sib)")).skip.?);
    try testing.expectEqual(SkipReason.html_filter, (try parseOne(&parser, "example.com##^script:has-text(ad)")).skip.?);
    try testing.expectEqual(SkipReason.procedural, (try parseOne(&parser, "example.com##.box:has(> .ad)")).skip.?);
    try testing.expectEqual(SkipReason.cosmetic_exception, (try parseOne(&parser, "example.com#@#.ad-banner")).skip.?);
    try testing.expectEqual(SkipReason.hosts_entry, (try parseOne(&parser, "0.0.0.0 ads.example.com")).skip.?);
}

test "a regular expression filter is not mistaken for an option list" {
    var parser: Parser = .{ .gpa = testing.allocator };
    defer parser.deinit();

    const filter = try parseOne(&parser, "/^https?:\\/\\/ads\\./");
    try testing.expectEqual(Kind.network, filter.kind);
    try testing.expectEqualStrings("/^https?:\\/\\/ads\\./", filter.pattern);
}
