# Fork: Sung Pae <self@sungpae.com>
# Maintainer: Levente Polyak <anthraxx[at]archlinux[dot]org>
# Maintainer: Andreas 'Segaja' Schleifer <segaja at archlinux dot org>
# Contributor: Eli Schwartz <eschwartz@archlinux.org>
# Contributor: lp76 <l.peduto@gmail.com>
# Contributor: Daenyth <Daenyth+Arch AT gmail DOT com>
# Contributor: Gaetan Bisson <bisson@archlinux.org>

pkgname=ncdu-nerv
pkgver=2.1
pkgrel=2
pkgdesc='Disk usage analyzer with an ncurses interface'
url='https://dev.yorhel.nl/ncdu'
license=('MIT')
depends=('ncurses')
makedepends=('zig')
arch=('x86_64')

build() {
    cd "$startdir"

    zig build -Drelease-safe -Dcpu=baseline

    make doc
}

check() {
    cd "$startdir"

    zig build test
}

package() {
    cd "$startdir"

    install -D --mode=755 "./zig-out/bin/${pkgname%-nerv}" "${pkgdir}/usr/bin/${pkgname%-nerv}"

    make install-doc PREFIX="${pkgdir}/usr"

    install -D --mode=644 LICENSES/MIT.txt "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
