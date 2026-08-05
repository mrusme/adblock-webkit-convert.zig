# adblock-webkit-convert.zig

Zig library that converts AdBlock and uBlock Origin filter lists into the WebKit
content blocker JSON that Safari reads and that WebKitGTK's
`WebKitUserContentFilterStore` compiles, with no dependencies beyond the
standard library. Includes a command line tool for checking output by hand.

The library downloads the lists it is given URLs for, so a program using it
needs no HTTP code of its own.

## Use

```sh
zig fetch --save git+https://tty.fail/mrus/adblock-webkit-convert.zig
```

Then in `build.zig`:

```zig
const adblock = b.dependency("adblock_webkit_convert", .{
    .target = target,
    .optimize = optimize,
});
exe_module.addImport("adblock_webkit_convert", adblock.module("adblock_webkit_convert"));
```

A conversion is a list of mappings, each naming where a list comes from and
where its JSON goes:

```zig
const adblock = @import("adblock_webkit_convert");

var report = try adblock.convertAll(gpa, io, &.{
    .{
        .source = .{ .url = "https://easylist.to/easylist/easylist.txt" },
        .target = .{ .file = "/home/you/.local/share/filters/easylist.json" },
    },
    .{
        .source = .{ .url = "https://secure.fanboy.co.nz/fanboy-annoyance.txt" },
        .target = .{ .file = "/home/you/.local/share/filters/fanboy-annoyance.json" },
    },
}, .{ .max_age = .fromSeconds(168 * 3600) });
defer report.deinit();

for (report.results) |result| switch (result.outcome) {
    .converted => {},
    .fresh => {},
    .failed => std.log.warn("{t}: {t}", .{ result.failure.?.stage, result.failure.?.err }),
};
```

Sources are `.buffer`, `.file` or `.url`. Targets are `.buffer` or `.file`. The
same list of mappings converts the first time and refreshes every time after.
`max_age` compares the target file's modification date against the clock and
leaves a target newer than it alone, so a program can call this on every start
and only actually refresh over the network when something has aged out. However,
buffer targets have no modification date and therefor always convert. Writes are
atomic, so an interrupted run leaves either the old file or the new one, never a
half written JSON that WebKit would then reject.

The directory a file target is in has to exist, because the library only writes
files and does not create directories.

### Rule limit

WebKit rejects a rule list past 150,000 rules with
`Too many rules in JSON
array`, and rejects the whole file rather than the rules
past the limit. A list longer than `max_rules_per_file` is therefore written as
several files. The first keeps the name it was asked for and the rest get `-2`,
`-3` and so on in front of the extension. Parts left behind by a run that used
to produce more of them are deleted. Setting the option to zero writes one file
however long it is.

## Command line

```sh
adblock-webkit-convert https://easylist.to/easylist/easylist.txt easylist.json
adblock-webkit-convert easylist.txt -            # to standard output
adblock-webkit-convert --max-age 168 <url> <path>
```

Options are `--max-age <hours>`, `--max-rules <n>`, `--keep-duplicates` and
`--quiet`. Sources and targets come in pairs, so several lists convert in one
run.

## Conversion

Network filters become `block` rules, `@@` exceptions become
`ignore-previous-rules`, and `##` cosmetic filters become `css-display-none`.
Options that map onto a trigger are handled with `third-party`, `first-party`,
`match-case`, `important`, `domain=`, `from=` and the resource types.

A pattern ending in `^` produces two rules, as the separator matches a character
that cannot appear in a hostname, and a URL that stops exactly where the pattern
stops has no such character to match, so the second rule carries an end anchor
instead.

Identical rules are dropped, keeping the first, because lists repeat themselves
and two filters that differ in syntax often mean the same rule once converted.

### Rules

- Conversion is done by best effort, but where a filter has no WebKit equivalent
  it is dropped.
- Scriptlet injection (`##+js(...)`), cosmetic exceptions (`#@#`), HTML
  filtering (`##^`) and procedural selectors (`:has()`, `:has-text()`,
  `:xpath()`, `:not()` and the rest) have no counterpart at all.
- Options carrying an instruction rather than a condition are dropped whole
  (`redirect=`, `csp=`, `removeparam=`, `replace=`, `header=`, `method=`,
  `denyallow=`, ...), and so is any unknown modifier.
- A WebKit trigger takes either `if-domain` or `unless-domain` and never both,
  so a filter naming domains on both sides is dropped. uBlock Origin's entity
  syntax (`example.*`) and regular expressions as domain values have no WebKit
  equivalent either.
- Patterns are checked against the subset WebKit's engine compiles, so whatever
  won't fit that is dropped.
- WebKit turns every `url-filter` into a finite state machine, so it takes
  literals, character classes, groups, quantifiers, a start anchor at the front,
  and an end anchor at the back.
- Alternation, numeric quantifiers, shorthand classes such as `\d` and `\w`,
  word boundaries, lookaround and non-ASCII are all rejected.
- `\d`, `\D`, `\w` and `\W` are expanded to their ASCII ranges first, and `{n,}`
  is approximated with `+`, so a pattern using only those still converts.

### Impact

Measured against the lists as they stand today, all of which compile in
WebKitGTK 2.50:

| List                 | Rules   | Filters skipped |
| -------------------- | ------- | --------------- |
| EasyList             | 141,866 | 1,734           |
| EasyPrivacy          | 102,471 | 98              |
| Fanboy Annoyance     | 50,024  | 4,414           |
| RU AdList            | 35,759  | 1,382           |
| Fanboy Cookiemonster | 24,937  | 481             |
| Liste FR             | 18,729  | 185             |
| Fanboy Social        | 13,618  | 213             |
| ABPindo              | 10,262  | 320             |
| EasyList Germany     | 5,948   | 435             |

Annoyance lists lose the most, because scriptlets and procedural selectors are
most of what they are made of.

## Inspiration

The conversion rules follow [ublock-webkit-filters][ubwf], a Go tool doing the
same job, whose source was the reference for which filters convert and how. This
library here is basically a reimplementation of that, but in Zig. It has no
regular expression engine behind it, since Zig's standard library has none, and
it validates patterns against WebKit's documented subset instead of against a
general regular expression parser, which makes it stricter in a few places.

## Tests

```sh
zig build test
```

Nothing in the test suite calls out to the network.

## License

Normally this would be released under Version 1.1 of the
[SEGV License](https://xn--gckvb8fzb.com/segv/), but because I took inspiration
from [ublock-webkit-filters][ubwf], this library follows the same [GPLv3
license][LICENSE] as the original Go tool.

[ubwf]: https://github.com/bnema/ublock-webkit-filters
[LICENSE]: LICENSE
