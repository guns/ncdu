# ncdu-zig

## Description

Ncdu is a disk usage analyzer with an ncurses interface. It is designed to find
space hogs on a remote server where you don't have an entire graphical setup
available, but it is a useful tool even on regular desktop systems. Ncdu aims
to be fast, simple and easy to use, and should be able to run in any minimal
POSIX-like environment with ncurses installed.

## This Zig implementation

This branch represents an experimental rewrite of ncdu using the [Zig
programming language](https://ziglang.org/). It is supposed to be fully
compatible (in terms of behavior, UI and CLI flags) with the C version, so it
can eventually be used as a drop-in replacement.

Since Zig itself is still very much unstable and things tend to break with each
release, I can't in good conscience publish this rewrite as a proper release of
ncdu (...yet). I intent to maintain the C version as long as necessary while
Zig matures and gets more widely supported among Linux/BSD systems. 

This rewrite is a test-bed for various improvements to the design of ncdu that
would impact large parts of its codebase. The improvements may also be
backported to the C version, depending on how viable a proper Zig release is.

### Implementation status

Missing features:

- Export/import
- Most directory listing settings
- Lots of informational UI windows
- Directory refresh
- File deletion
- Opening a shell
- OOM handling

### Improvements compared to the C version

Already implemented:

- Significantly reduced memory usage, achieved by:
  - Removing pointers between nodes that are not strictly necessary for basic
    tree traversal (this impacts *all* code in the C version of ncdu).
  - Using separate structs for directory, file and hard link nodes, each storing
    only the information necessary for that particular type of node.
  - Using an arena allocator and getting rid of data alignment.
- Improved performance of hard link counting (fixing
  [#121](https://code.blicky.net/yorhel/ncdu/issues/121)).
- Add support for separate counting hard links that are shared with other
  directories or unique within the directory (issue
  [#36](https://code.blicky.net/yorhel/ncdu/issues/36)).
  (Implemented in the data model, but not displayed in the UI yet)
- Faster --exclude-kernfs thanks to `statfs()` caching.
- Improved handling of Unicode and special characters.
- Remembers item position when switching directories.

Potentially to be implemented:

- Faster --exclude-pattern matching
- Multithreaded scanning

### Regressions compared to the C version

Aside from this implementation being unfinished:

- Assumes a UTF-8 locale and terminal.
- No doubt somewhat less portable.

## Requirements

- Latest Zig compiler
- Some sort of POSIX-like OS
- ncurses libraries and header files

## Install

**todo**
