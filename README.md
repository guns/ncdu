<!--
SPDX-FileCopyrightText: 2021 Yoran Heling <projects@yorhel.nl>
SPDX-License-Identifier: MIT
-->

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

### Improvements compared to the C version

- Significantly reduced memory usage, achieved by:
  - Removing pointers between nodes that are not strictly necessary for basic
    tree traversal (this impacts *all* code in the C version of ncdu).
  - Using separate structs for directory, file and hard link nodes, each storing
    only the information necessary for that particular type of node.
  - Using an arena allocator and getting rid of data alignment.
  - Refreshing a directory no longer creates a full copy of the (sub)tree.
- Improved performance of hard link counting (fixing
  [#121](https://code.blicky.net/yorhel/ncdu/issues/121)).
- Add support for separate counting hard links that are shared with other
  directories or unique within the directory (issue
  [#36](https://code.blicky.net/yorhel/ncdu/issues/36)).
- Faster --exclude-kernfs thanks to `statfs()` caching.
- Improved handling of Unicode and special characters.
- Key to switch to path from a file's hard link listing.
- Remembers item position when switching directories.

Potentially to be implemented:

- Faster --exclude-pattern matching
- Multithreaded scanning
- Exporting a JSON dump after scanning into RAM
- Transparent dump (de)compression by piping through gzip/bzip2/etc

### Regressions compared to the C version

Aside from this implementation being unfinished:

- Assumes a UTF-8 locale and terminal.
- No doubt somewhat less portable.
- Listing all paths for a particular hard link requires a full search through
  the in-memory directory tree.
- Not nearly as well tested.
- Directories that could not be opened are displayed as files.
- The disk usage of directory entries themselves is not updated during refresh.

### Minor UI differences

Not sure if these count as improvements or regressions, so I'll just list these
separately:

- The browsing UI is not visible during refresh or file deletion.
- Some columns in the file browser are hidden automatically if the terminal is
  not wide enough to display them.
- The file's path is not displayed in the item window anymore (it's redundant).
- The item window's height is dynamic based on its contents.

## Requirements

- Zig 8.0
- Some sort of POSIX-like OS
- ncurses libraries and header files

## Install

**todo**
