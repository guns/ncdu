# Optional semi-standard Makefile with some handy tools.
# Ncdu itself can be built with just the zig build system.

PREFIX ?= /usr/local
BINDIR ?= ${PREFIX}/bin
MANDIR ?= ${PREFIX}/share/man/man1

NCDU_VERSION=$(shell grep 'program_version = "' src/main.zig | sed -e 's/^.*"\(.\+\)".*$$/\1/')

debug:
	zig build

release:
	zig build -Drelease-fast

clean:
	rm -rf zig-cache zig-out

distclean: clean
	rm -f ncdu.1

doc: ncdu.1

ncdu.1: ncdu.pod src/main.zig
	pod2man --center "ncdu manual" --release "ncdu-${NCDU_VERSION}" ncdu.pod >ncdu.1

install: install-bin install-doc

install-bin: release
	mkdir -p ${BINDIR}
	install -m0755 zig-out/bin/ncdu ${BINDIR}/

install-doc: doc
	mkdir -p ${MANDIR}
	install -m0644 ncdu.1 ${MANDIR}/

uninstall: uninstall-bin uninstall-doc

# XXX: Ideally, these would also remove the directories created by 'install' if they are empty.
uninstall-bin:
	rm -f ${BINDIR}/ncdu

uninstall-doc:
	rm -f ${MANDIR}/ncdu.1

dist: doc
	rm -f ncdu-${NCDU_VERSION}.tar.gz
	mkdir ncdu-${NCDU_VERSION}
	for f in ncdu.1 `git ls-files | grep -v ^\.gitignore`; do mkdir -p ncdu-${NCDU_VERSION}/`dirname $$f`; ln -s "`pwd`/$$f" ncdu-${NCDU_VERSION}/$$f; done
	tar -cophzf ncdu-${NCDU_VERSION}.tar.gz --sort=name ncdu-${NCDU_VERSION}
	rm -rf ncdu-${NCDU_VERSION}


# ASSUMPTION: the ncurses source tree has been extracted into ncurses/
# BUG: Zig writes to zig-* in this directory, not the TARGET-specific build one.
# BUG: Doesn't seem to do any static linking :(
static:
	mkdir -p static-${TARGET}/nc static-${TARGET}/inst/pkg
	cd static-${TARGET}/nc && ../../ncurses/configure --prefix="`pwd`/../inst"\
		--with-pkg-config-libdir="`pwd`/../inst/pkg"\
		--without-cxx --without-cxx-binding --without-ada --without-manpages --without-progs\
		--without-tests --enable-pc-files --without-pkg-config --without-shared --without-debug\
		--without-gpm --without-sysmouse --enable-widec --with-default-terminfo-dir=/usr/share/terminfo\
		--with-terminfo-dirs=/usr/share/terminfo:/lib/terminfo:/usr/local/share/terminfo\
		--with-fallbacks="screen linux vt100 xterm xterm-256color" --host=${TARGET}\
		CC="zig cc --target=${TARGET}"\
		LD="zig cc --target=${TARGET}"\
		AR="zig ar" RANLIB="zig ranlib"\
		CPPFLAGS=-D_GNU_SOURCE && make && make install.libs
	cd static-${TARGET} && PKG_CONFIG_LIBDIR="`pwd`/inst/pkg" zig build -Dtarget=${TARGET}\
		--build-file ../build.zig --search-prefix inst/ --cache-dir zig -Drelease-fast=true
	@# Alternative approach, bypassing zig-build, but this still refuses to do static linking ("UnableToStaticLink")
	@# cd static-${TARGET} && zig build-exe -target ${TARGET} -lc -Iinst/include -Iinst/include/ncursesw -Linst/lib -lncursesw -static ../src/main.zig ../src/ncurses_refs.c
	#rm -rf static-${TARGET}

static-target-%:
	$(MAKE) static TARGET=$*

static-all:\
	# static-target-x86_64-linux-musl \ # Works, but doesn't link statically
	# static-target-aarch64-linux-musl \ # Same
	# static-target-i386-linux-musl # Broken, linker errors
