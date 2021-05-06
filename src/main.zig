pub const program_version = "2.0";

const std = @import("std");
const model = @import("model.zig");
const scan = @import("scan.zig");
const ui = @import("ui.zig");
const browser = @import("browser.zig");
const c = @cImport(@cInclude("locale.h"));

pub const allocator = std.heap.c_allocator;

pub const Config = struct {
    same_fs: bool = true,
    extended: bool = false,
    follow_symlinks: bool = false,
    exclude_caches: bool = false,
    exclude_kernfs: bool = false,
    exclude_patterns: std.ArrayList([:0]const u8) = std.ArrayList([:0]const u8).init(allocator),

    update_delay: u32 = 100,
    si: bool = false,
    nc_tty: bool = false,
    ui_color: enum { off, dark } = .off,
    thousands_sep: []const u8 = ".",

    show_hidden: bool = true,
    show_blocks: bool = true,
    sort_col: enum { name, blocks, size, items, mtime } = .blocks,
    sort_order: enum { asc, desc } = .desc,
    sort_dirsfirst: bool = false,

    read_only: bool = false,
    can_shell: bool = true,
    confirm_quit: bool = false,
};

pub var config = Config{};

// Simple generic argument parser, supports getopt_long() style arguments.
// T can be any type that has a 'fn next(T) ?[:0]const u8' method, e.g.:
//   var args = Args(std.process.ArgIteratorPosix).init(std.process.ArgIteratorPosix.init());
fn Args(T: anytype) type {
    return struct {
        it: T,
        short: ?[:0]const u8 = null, // Remainder after a short option, e.g. -x<stuff> (which may be either more short options or an argument)
        last: ?[]const u8 = null,
        last_arg: ?[:0]const u8 = null, // In the case of --option=<arg>
        shortbuf: [2]u8 = undefined,
        argsep: bool = false,

        const Self = @This();
        const Option = struct {
            opt: bool,
            val: []const u8,

            fn is(self: @This(), cmp: []const u8) bool {
                return self.opt and std.mem.eql(u8, self.val, cmp);
            }
        };

        fn init(it: T) Self {
            return Self{ .it = it };
        }

        fn shortopt(self: *Self, s: [:0]const u8) Option {
            self.shortbuf[0] = '-';
            self.shortbuf[1] = s[0];
            self.short = if (s.len > 1) s[1.. :0] else null;
            self.last = &self.shortbuf;
            return .{ .opt = true, .val = &self.shortbuf };
        }

        /// Return the next option or positional argument.
        /// 'opt' indicates whether it's an option or positional argument,
        /// 'val' will be either -x, --something or the argument.
        pub fn next(self: *Self) ?Option {
            if (self.last_arg != null) ui.die("Option '{s}' does not expect an argument.\n", .{ self.last.? });
            if (self.short) |s| return self.shortopt(s);
            const val = self.it.next() orelse return null;
            if (self.argsep or val.len == 0 or val[0] != '-') return Option{ .opt = false, .val = val };
            if (val.len == 1) ui.die("Invalid option '-'.\n", .{});
            if (val.len == 2 and val[1] == '-') {
                self.argsep = true;
                return self.next();
            }
            if (val[1] == '-') {
                if (std.mem.indexOfScalar(u8, val, '=')) |sep| {
                    if (sep == 2) ui.die("Invalid option '{s}'.\n", .{val});
                    self.last_arg = val[sep+1.. :0];
                    self.last = val[0..sep];
                    return Option{ .opt = true, .val = self.last.? };
                }
                self.last = val;
                return Option{ .opt = true, .val = val };
            }
            return self.shortopt(val[1..:0]);
        }

        /// Returns the argument given to the last returned option. Dies with an error if no argument is provided.
        pub fn arg(self: *Self) [:0]const u8 {
            if (self.short) |a| {
                defer self.short = null;
                return a;
            }
            if (self.last_arg) |a| {
                defer self.last_arg = null;
                return a;
            }
            if (self.it.next()) |o| return o;
            ui.die("Option '{s}' requires an argument.\n", .{ self.last.? });
        }
    };
}


// For debugging
fn writeTree(out: anytype, e: *model.Entry, indent: u32) @TypeOf(out).Error!void {
    var i: u32 = 0;
    while (i<indent) {
        try out.writeByte(' ');
        i += 1;
    }
    try out.print("{s}  blocks={d}  size={d}", .{ e.name(), e.blocks, e.size });

    if (e.dir()) |d| {
        try out.print("  blocks={d}-{d}  size={d}-{d}  items={d}-{d}  dev={x}", .{
            d.total_blocks, d.shared_blocks,
            d.total_size, d.shared_size,
            d.total_items, d.shared_items, d.dev
        });
        if (d.err) try out.writeAll("  err");
        if (d.suberr) try out.writeAll("  suberr");
    } else if (e.file()) |f| {
        if (f.err) try out.writeAll("  err");
        if (f.excluded) try out.writeAll("  excluded");
        if (f.other_fs) try out.writeAll("  other_fs");
        if (f.kernfs) try out.writeAll("  kernfs");
        if (f.notreg) try out.writeAll("  notreg");
    } else if (e.link()) |l| {
        try out.print("  ino={x}  nlinks={d}", .{ l.ino, l.nlink });
    }
    if (e.ext()) |ext|
        try out.print("  mtime={d}  uid={d}  gid={d}  mode={o}", .{ ext.mtime, ext.uid, ext.gid, ext.mode });

    try out.writeByte('\n');
    if (e.dir()) |d| {
        var s = d.sub;
        while (s) |sub| {
            try writeTree(out, sub, indent+4);
            s = sub.next;
        }
    }
}

fn version() noreturn {
    std.io.getStdOut().writer().writeAll("ncdu " ++ program_version ++ "\n") catch {};
    std.process.exit(0);
}

fn help() noreturn {
    std.io.getStdOut().writer().writeAll(
        "ncdu <options> <directory>\n\n"
     ++ "  -h,--help                  This help message\n"
     ++ "  -q                         Quiet mode, refresh interval 2 seconds\n"
     ++ "  -v,-V,--version            Print version\n"
     ++ "  -x                         Same filesystem\n"
     ++ "  -e                         Enable extended information\n"
     ++ "  -r                         Read only\n"
     ++ "  -o FILE                    Export scanned directory to FILE\n"
     ++ "  -f FILE                    Import scanned directory from FILE\n"
     ++ "  -0,-1,-2                   UI to use when scanning (0=none,2=full ncurses)\n"
     ++ "  --si                       Use base 10 (SI) prefixes instead of base 2\n"
     ++ "  --exclude PATTERN          Exclude files that match PATTERN\n"
     ++ "  -X, --exclude-from FILE    Exclude files that match any pattern in FILE\n"
     ++ "  -L, --follow-symlinks      Follow symbolic links (excluding directories)\n"
     ++ "  --exclude-caches           Exclude directories containing CACHEDIR.TAG\n"
     ++ "  --exclude-kernfs           Exclude Linux pseudo filesystems (procfs,sysfs,cgroup,...)\n"
     ++ "  --confirm-quit             Confirm quitting ncdu\n"
     ++ "  --color SCHEME             Set color scheme (off/dark)\n"
    ) catch {};
    std.process.exit(0);
}

fn readExcludeFile(path: []const u8) !void {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var rd = std.io.bufferedReader(f.reader()).reader();
    var buf = std.ArrayList(u8).init(allocator);
    while (true) {
        rd.readUntilDelimiterArrayList(&buf, '\n', 4096)
            catch |e| if (e != error.EndOfStream) return e else if (buf.items.len == 0) break;
        if (buf.items.len > 0)
            try config.exclude_patterns.append(try buf.toOwnedSliceSentinel(0));
    }
}

pub fn main() anyerror!void {
    // Grab thousands_sep from the current C locale.
    // (We can safely remove this when not linking against libc, it's a somewhat obscure feature)
    _ = c.setlocale(c.LC_ALL, "");
    if (c.localeconv()) |locale| {
        if (locale.*.thousands_sep) |sep| {
            const span = std.mem.spanZ(sep);
            if (span.len > 0)
                config.thousands_sep = span;
        }
    }

    var args = Args(std.process.ArgIteratorPosix).init(std.process.ArgIteratorPosix.init());
    var scan_dir: ?[]const u8 = null;
    _ = args.next(); // program name
    while (args.next()) |opt| {
        if (!opt.opt) {
            // XXX: ncdu 1.x doesn't error, it just silently ignores all but the last argument.
            if (scan_dir != null) ui.die("Multiple directories given, see ncdu -h for help.\n", .{});
            scan_dir = opt.val;
            continue;
        }
        if (opt.is("-h") or opt.is("-?") or opt.is("--help")) help()
        else if(opt.is("-v") or opt.is("-V") or opt.is("--version")) version()
        else if(opt.is("-q")) config.update_delay = 2000
        else if(opt.is("-x")) config.same_fs = true
        else if(opt.is("-e")) config.extended = true
        else if(opt.is("-r") and config.read_only) config.can_shell = false
        else if(opt.is("-r")) config.read_only = true
        else if(opt.is("--si")) config.si = true
        else if(opt.is("-L") or opt.is("--follow-symlinks")) config.follow_symlinks = true
        else if(opt.is("--exclude")) try config.exclude_patterns.append(args.arg())
        else if(opt.is("-X") or opt.is("--exclude-from")) {
            const arg = args.arg();
            readExcludeFile(arg) catch |e| ui.die("Error reading excludes from {s}: {}.\n", .{ arg, e });
        } else if(opt.is("--exclude-caches")) config.exclude_caches = true
        else if(opt.is("--exclude-kernfs")) config.exclude_kernfs = true
        else if(opt.is("--confirm-quit")) config.confirm_quit = true
        else if(opt.is("--color")) {
            const val = args.arg();
            if (std.mem.eql(u8, val, "off")) config.ui_color = .off
            else if (std.mem.eql(u8, val, "dark")) config.ui_color = .dark
            else ui.die("Unknown --color option: {s}.\n", .{val});
        } else ui.die("Unrecognized option '{s}'.\n", .{opt.val});
        // TODO: -o, -f, -0, -1, -2
    }

    if (std.builtin.os.tag != .linux and config.exclude_kernfs)
        ui.die("The --exclude-kernfs tag is currently only supported on Linux.\n", .{});

    try scan.scanRoot(scan_dir orelse ".");
    try browser.open(model.Parents{});

    ui.init();
    defer ui.deinit();

    try browser.draw();

    _ = ui.c.getch();

    //var out = std.io.bufferedWriter(std.io.getStdOut().writer());
    //try writeTree(out.writer(), &model.root.entry, 0);
    //try out.flush();
}


test "argument parser" {
    const L = struct {
        lst: []const [:0]const u8,
        idx: usize = 0,
        fn next(s: *@This()) ?[:0]const u8 {
            if (s.idx == s.lst.len) return null;
            defer s.idx += 1;
            return s.lst[s.idx];
        }
    };
    const lst = [_][:0]const u8{ "a", "-abcd=e", "--opt1=arg1", "--opt2", "arg2", "-x", "foo", "", "--", "--arg", "", "-", };
    const l = L{ .lst = &lst };
    const T = struct {
        a: Args(L),
        fn opt(self: *@This(), isopt: bool, val: []const u8) void {
            const o = self.a.next().?;
            std.testing.expectEqual(isopt, o.opt);
            std.testing.expectEqualStrings(val, o.val);
            std.testing.expectEqual(o.is(val), isopt);
        }
        fn arg(self: *@This(), val: []const u8) void {
            std.testing.expectEqualStrings(val, self.a.arg());
        }
    };
    var t = T{ .a = Args(L).init(l) };
    t.opt(false, "a");
    t.opt(true, "-a");
    t.opt(true, "-b");
    t.arg("cd=e");
    t.opt(true, "--opt1");
    t.arg("arg1");
    t.opt(true, "--opt2");
    t.arg("arg2");
    t.opt(true, "-x");
    t.arg("foo");
    t.opt(false, "");
    t.opt(false, "--arg");
    t.opt(false, "");
    t.opt(false, "-");
    std.testing.expectEqual(t.a.next(), null);
}
