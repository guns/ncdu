const std = @import("std");
const model = @import("model.zig");
const scan = @import("scan.zig");

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = &general_purpose_allocator.allocator;

pub const Config = struct {
    same_fs: bool = true,
    extended: bool = false,
    exclude_caches: bool = false,
    follow_symlinks: bool = false,
    exclude_kernfs: bool = false,
    // TODO: exclude patterns

    update_delay: u32 = 100,
    si: bool = false,
    // TODO: color scheme

    read_only: bool = false,
    can_shell: bool = true,
    confirm_quit: bool = false,
};

pub var config = Config{};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    _ = std.io.getStdErr().writer().print(fmt, args) catch {};
    std.process.exit(1);
}

// Simple generic argument parser, supports getopt_long() style arguments.
// T can be any type that has a 'fn next(T) ?[]const u8' method, e.g.:
//   var args = Args(std.process.ArgIteratorPosix).init(std.process.ArgIteratorPosix.init());
fn Args(T: anytype) type {
    return struct {
        it: T,
        short: ?[]const u8 = null, // Remainder after a short option, e.g. -x<stuff> (which may be either more short options or an argument)
        last: ?[]const u8 = null,
        last_arg: ?[]const u8 = null, // In the case of --option=<arg>
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

        pub fn shortopt(self: *Self, s: []const u8) Option {
            self.shortbuf[0] = '-';
            self.shortbuf[1] = s[0];
            self.short = if (s.len > 1) s[1..] else null;
            self.last = &self.shortbuf;
            return .{ .opt = true, .val = &self.shortbuf };
        }

        /// Return the next option or positional argument.
        /// 'opt' indicates whether it's an option or positional argument,
        /// 'val' will be either -x, --something or the argument.
        pub fn next(self: *Self) ?Option {
            if (self.last_arg != null) die("Option '{s}' does not expect an argument.\n", .{ self.last.? });
            if (self.short) |s| return self.shortopt(s);
            const val = self.it.next() orelse return null;
            if (self.argsep or val.len == 0 or val[0] != '-') return Option{ .opt = false, .val = val };
            if (val.len == 1) die("Invalid option '-'.\n", .{});
            if (val.len == 2 and val[1] == '-') {
                self.argsep = true;
                return self.next();
            }
            if (val[1] == '-') {
                if (std.mem.indexOfScalar(u8, val, '=')) |sep| {
                    if (sep == 2) die("Invalid option '{s}'.\n", .{val});
                    self.last_arg = val[sep+1.. :0];
                    self.last = val[0..sep];
                    return Option{ .opt = true, .val = self.last.? };
                }
                self.last = val;
                return Option{ .opt = true, .val = val };
            }
            return self.shortopt(val[1..]);
        }

        /// Returns the argument given to the last returned option. Dies with an error if no argument is provided.
        pub fn arg(self: *Self) []const u8 {
            if (self.short) |a| {
                defer self.short = null;
                return a;
            }
            if (self.last_arg) |a| {
                defer self.last_arg = null;
                return a;
            }
            if (self.it.next()) |o| return o;
            die("Option '{s}' requires an argument.\n", .{ self.last.? });
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
    // TODO: don't hardcode this version here.
    _ = std.io.getStdOut().writer().writeAll("ncdu 2.0\n") catch {};
    std.process.exit(0);
}

fn help() noreturn {
    // TODO
    _ = std.io.getStdOut().writer().writeAll("ncdu 2.0\n") catch {};
    std.process.exit(0);
}

pub fn main() anyerror!void {
    var args = Args(std.process.ArgIteratorPosix).init(std.process.ArgIteratorPosix.init());
    var scan_dir: ?[]const u8 = null;
    _ = args.next(); // program name
    while (args.next()) |opt| {
        if (!opt.opt) {
            // XXX: ncdu 1.x doesn't error, it just silently ignores all but the last argument.
            if (scan_dir != null) die("Multiple directories given, see ncdu -h for help.\n", .{});
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
        else if(opt.is("--exclude-caches")) config.exclude_caches = true
        else if(opt.is("--exclude-kernfs")) config.exclude_kernfs = true
        else if(opt.is("--confirm-quit")) config.confirm_quit = true
        else die("Unrecognized option '{s}'.\n", .{opt.val});
        // TODO: -o, -f, -0, -1, -2, --exclude, -X, --exclude-from, --color
    }

    std.log.info("align={}, Entry={}, Dir={}, Link={}, File={}.",
        .{@alignOf(model.Dir), @sizeOf(model.Entry), @sizeOf(model.Dir), @sizeOf(model.Link), @sizeOf(model.File)});
    try scan.scanRoot(scan_dir orelse ".");

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
