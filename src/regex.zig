const std = @import("std");

const Allocator = std.mem.Allocator;

/// `^` in a pattern means any character that cannot appear in a hostname
/// or a path component. WebKit takes no alternation, so this is a character
/// class rather than a group.
const separator_class = "[^%.0-9a-z_-]";

const hostname_anchor = "^[a-z-]+://([^/?#]+\\.)?";
const hostname_anchor_dot = "^[a-z-]+://([^/?#]+)?";

pub const Rewriter = struct {
    gpa: Allocator,
    /// Escaped bytes, before the anchors and the wildcards.
    stage: std.ArrayList(u8) = .empty,
    /// Finished expression.
    out: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Rewriter) void {
        self.stage.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    /// Result borrows the rewriter and is valid until the next call.
    pub fn fromPattern(self: *Rewriter, pattern: []const u8) Allocator.Error![]const u8 {
        self.out.clearRetainingCapacity();

        if (pattern.len == 0 or std.mem.eql(u8, pattern, "*")) {
            try self.out.appendSlice(self.gpa, ".*");
            return self.out.items;
        }

        var body = pattern;
        var hostname = false;
        var left = false;
        var right = false;

        if (std.mem.startsWith(u8, body, "||")) {
            hostname = true;
            body = body[2..];
        } else if (std.mem.startsWith(u8, body, "|")) {
            left = true;
            body = body[1..];
        }
        if (std.mem.endsWith(u8, body, "|")) {
            right = true;
            body = body[0 .. body.len - 1];
        }

        // Pattern written as regular expression is taken as it is, with
        // shorthand classes expanded where expansion exists. Anything
        // not supported is caught by `isValid`.
        if (body.len > 2 and body[0] == '/' and body[body.len - 1] == '/') {
            try self.expandClasses(body[1 .. body.len - 1]);
            return self.out.items;
        }

        try self.escape(body);

        // Wildcards at either end match what unanchored expression already
        // matches.
        var escaped = self.stage.items;
        while (escaped.len > 0 and escaped[0] == '*') escaped = escaped[1..];
        while (escaped.len > 0 and escaped[escaped.len - 1] == '*') escaped = escaped[0 .. escaped.len - 1];

        if (hostname) {
            const anchor = if (std.mem.startsWith(u8, escaped, "\\."))
                hostname_anchor_dot
            else
                hostname_anchor;
            try self.out.appendSlice(self.gpa, anchor);
        } else if (left) {
            try self.out.append(self.gpa, '^');
        }

        var index: usize = 0;
        while (index < escaped.len) {
            if (escaped[index] != '*') {
                try self.out.append(self.gpa, escaped[index]);
                index += 1;
                continue;
            }
            try self.out.appendSlice(self.gpa, ".*");
            while (index < escaped.len and escaped[index] == '*') index += 1;
        }

        if (right) try self.out.append(self.gpa, '$');
        return self.out.items;
    }

    /// Variant for a pattern ending in `^`, matches a separator and
    /// also the end of the URL. One expression not enough, so caller emits
    /// second rule.
    pub fn fromPatternEndAnchored(self: *Rewriter, pattern: []const u8) Allocator.Error![]const u8 {
        var trimmed = pattern;
        if (std.mem.endsWith(u8, trimmed, "|")) trimmed = trimmed[0 .. trimmed.len - 1];
        if (std.mem.endsWith(u8, trimmed, "^")) trimmed = trimmed[0 .. trimmed.len - 1];

        _ = try self.fromPattern(trimmed);
        if (!std.mem.endsWith(u8, self.out.items, "$")) try self.out.append(self.gpa, '$');
        return self.out.items;
    }

    /// Escapes every that's a metacharacter but a literal in pattern, turns
    /// `^` into separator class. `*` is left for wildcard pass.
    fn escape(self: *Rewriter, body: []const u8) Allocator.Error!void {
        self.stage.clearRetainingCapacity();
        for (body) |ch| switch (ch) {
            '.', '+', '?', '$', '{', '}', '(', ')', '|', '[', ']', '\\' => {
                try self.stage.append(self.gpa, '\\');
                try self.stage.append(self.gpa, ch);
            },
            '^' => try self.stage.appendSlice(self.gpa, separator_class),
            else => try self.stage.append(self.gpa, ch),
        };
    }

    /// Replaces shorthand classes that have exact ASCII equivalent,
    /// approximates `{n,}` with `+`. `\s`, `\S`, `\b`, the rest are copied
    /// through so `isValid` can reject pattern.
    fn expandClasses(self: *Rewriter, pattern: []const u8) Allocator.Error!void {
        var in_class = false;
        var index: usize = 0;
        while (index < pattern.len) {
            const ch = pattern[index];

            if (ch == '\\' and index + 1 < pattern.len) {
                const next = pattern[index + 1];
                // Inside character class expansion has to be bare range.
                // `[[0-9]]` is not what `[\d]` means.
                // Negated shorthand has no equivalent inside class -> left for
                // validator.
                const expansion: ?[]const u8 = switch (next) {
                    'w' => if (in_class) "a-zA-Z0-9_" else "[a-zA-Z0-9_]",
                    'W' => if (in_class) null else "[^a-zA-Z0-9_]",
                    'd' => if (in_class) "0-9" else "[0-9]",
                    'D' => if (in_class) null else "[^0-9]",
                    else => null,
                };
                if (expansion) |text| {
                    try self.out.appendSlice(self.gpa, text);
                    index += 2;
                    continue;
                }
                try self.out.appendSlice(self.gpa, pattern[index .. index + 2]);
                index += 2;
                continue;
            }

            if (ch == '[') in_class = true;
            if (ch == ']') in_class = false;

            // `{n,}` is one or more of preceding atom past threshold, more or
            // less equivalent of WebKit `+`. `{n}` and `{n,m}` have no
            // approximation -> left for the validator.
            if (ch == '{' and !in_class) {
                if (openEndedQuantifier(pattern[index..])) |len| {
                    try self.out.append(self.gpa, '+');
                    index += len;
                    continue;
                }
            }

            try self.out.append(self.gpa, ch);
            index += 1;
        }
    }
};

/// Length of `{n,}` at front of `text`, or null when other brace expression.
fn openEndedQuantifier(text: []const u8) ?usize {
    std.debug.assert(text[0] == '{');
    var index: usize = 1;
    while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
    if (index == 1) return null;
    if (index + 1 >= text.len) return null;
    if (text[index] != ',' or text[index + 1] != '}') return null;
    return index + 2;
}

/// Ends in separator `^`? Then second end anchored rule.
pub fn endsWithSeparator(pattern: []const u8) bool {
    var trimmed = pattern;
    if (std.mem.endsWith(u8, trimmed, "|")) trimmed = trimmed[0 .. trimmed.len - 1];
    return std.mem.endsWith(u8, trimmed, "^");
}

pub fn isValid(pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    // Expression deeper than this costs WebKit more to compile than it is
    // worth.
    const max_depth = 32;
    var filled: [max_depth]bool = @splat(false);

    var depth: usize = 0;
    var index: usize = 0;
    var atom = false;

    while (index < pattern.len) {
        const ch = pattern[index];
        if (ch >= 0x80) return false;

        switch (ch) {
            '\\' => {
                if (index + 1 >= pattern.len) return false;
                const next = pattern[index + 1];
                // Escape stands for a literal, letter or a digit after
                // backslash is shorthand class, boundary assertion or back
                // reference. Unsupported by WebKit.
                if (std.ascii.isAlphanumeric(next) or next >= 0x80) return false;
                index += 2;
                atom = true;
            },
            '[' => {
                index = (classEnd(pattern, index) orelse return false) + 1;
                atom = true;
            },
            ']' => return false,
            '(' => {
                // `(?:`, `(?=`, `(?!`, `(?<=`, `(?<!` and `(?<name>` start this
                // way, none compile.
                if (index + 1 < pattern.len and pattern[index + 1] == '?') return false;
                if (depth == max_depth) return false;
                filled[depth] = false;
                depth += 1;
                index += 1;
                atom = false;
                continue;
            },
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
                // Empty group matches empty string -> matches every URL.
                if (!filled[depth]) return false;
                index += 1;
                atom = true;
            },
            '*', '+', '?' => {
                if (!atom) return false;
                index += 1;
                atom = false;
                continue;
            },
            '^' => {
                if (index != 0) return false;
                index += 1;
                atom = false;
                continue;
            },
            '$' => {
                if (index + 1 != pattern.len) return false;
                index += 1;
                atom = false;
                continue;
            },
            '|', '{', '}' => return false,
            else => {
                index += 1;
                atom = true;
            },
        }

        if (depth > 0) filled[depth - 1] = true;
    }

    return depth == 0;
}

/// Index of `]` closing class that opens at `open`, or null when class is
/// empty, unterminated, or contains something unsupported by WebKit.
fn classEnd(pattern: []const u8, open: usize) ?usize {
    var index = open + 1;
    if (index < pattern.len and pattern[index] == '^') index += 1;
    const first = index;

    while (index < pattern.len) : (index += 1) {
        const ch = pattern[index];
        if (ch >= 0x80) return null;
        if (ch == '\\') {
            if (index + 1 >= pattern.len) return null;
            const next = pattern[index + 1];
            if (std.ascii.isAlphanumeric(next) or next >= 0x80) return null;
            index += 1;
            continue;
        }
        if (ch == ']') return if (index == first) null else index;
    }

    return null;
}

const testing = std.testing;

fn expectPattern(pattern: []const u8, want: []const u8) !void {
    var rewriter: Rewriter = .{ .gpa = testing.allocator };
    defer rewriter.deinit();
    try testing.expectEqualStrings(want, try rewriter.fromPattern(pattern));
}

test "a hostname anchor becomes a scheme and an optional label" {
    try expectPattern("||ads.example.com^", "^[a-z-]+://([^/?#]+\\.)?ads\\.example\\.com[^%.0-9a-z_-]");
}

test "a hostname anchor in front of a dot takes the label free form" {
    try expectPattern("||.example.com", "^[a-z-]+://([^/?#]+)?\\.example\\.com");
}

test "a left anchor and a right anchor become the two anchors" {
    try expectPattern("|http://example.com/ad|", "^http://example\\.com/ad$");
}

test "wildcards become a dot star and runs collapse" {
    try expectPattern("/banner*/*.gif", "/banner.*/.*\\.gif");
}

test "wildcards at either end are dropped" {
    try expectPattern("*/ads/*", "/ads/");
}

test "an empty pattern and a bare wildcard match everything" {
    try expectPattern("", ".*");
    try expectPattern("*", ".*");
}

test "the end anchored variant replaces the separator" {
    var rewriter: Rewriter = .{ .gpa = testing.allocator };
    defer rewriter.deinit();
    try testing.expectEqualStrings(
        "^[a-z-]+://([^/?#]+\\.)?ads\\.example\\.com$",
        try rewriter.fromPatternEndAnchored("||ads.example.com^"),
    );
}

test "a regular expression pattern keeps its own syntax" {
    try expectPattern("/^https?:\\/\\/ads\\./", "^https?:\\/\\/ads\\.");
}

test "shorthand classes expand to ASCII ranges" {
    try expectPattern("/ad\\d\\w/", "ad[0-9][a-zA-Z0-9_]");
    try expectPattern("/[\\d\\w]/", "[0-9a-zA-Z0-9_]");
    try expectPattern("/\\W\\D/", "[^a-zA-Z0-9_][^0-9]");
}

test "an open ended numeric quantifier is approximated with a plus" {
    try expectPattern("/ad[0-9]{2,}/", "ad[0-9]+");
}

test "a separator only matches a non hostname character" {
    try expectPattern("ads^", "ads[^%.0-9a-z_-]");
}

test "the generated anchors pass the validator" {
    try testing.expect(isValid("^[a-z-]+://([^/?#]+\\.)?ads\\.example\\.com[^%.0-9a-z_-]"));
    try testing.expect(isValid("^[a-z-]+://([^/?#]+)?\\.example\\.com"));
    try testing.expect(isValid(".*"));
    try testing.expect(isValid("^http://example\\.com/ad$"));
}

test "the validator rejects what WebKit cannot compile" {
    try testing.expect(!isValid(""));
    try testing.expect(!isValid("ads|banners"));
    try testing.expect(!isValid("ad[0-9]{2}"));
    try testing.expect(!isValid("ad\\d"));
    try testing.expect(!isValid("ad\\b"));
    try testing.expect(!isValid("ad\\s"));
    try testing.expect(!isValid("(?:ads)"));
    try testing.expect(!isValid("(?=ads)"));
    try testing.expect(!isValid("(?<=ads)"));
    try testing.expect(!isValid("\\p{L}"));
    try testing.expect(!isValid("wérbung"));
    try testing.expect(!isValid("(ads"));
    try testing.expect(!isValid("ads)"));
    try testing.expect(!isValid("()"));
    try testing.expect(!isValid("[ads"));
    try testing.expect(!isValid("[]"));
    try testing.expect(!isValid("a$b"));
    try testing.expect(!isValid("a^b"));
    try testing.expect(!isValid("*ads"));
    try testing.expect(!isValid("ad**"));
    try testing.expect(!isValid("ads\\"));
}

test "a separator at the end is what needs a second rule" {
    try testing.expect(endsWithSeparator("||ads.example.com^"));
    try testing.expect(endsWithSeparator("||ads.example.com^|"));
    try testing.expect(!endsWithSeparator("||ads.example.com"));
    try testing.expect(!endsWithSeparator("||ads.example.com^/path"));
}
