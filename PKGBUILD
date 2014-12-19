# Contributor: lp76 <l.peduto@gmail.com>
# Contributor: Daenyth <Daenyth+Arch AT gmail DOT com>
# Maintainer: Gaetan Bisson <bisson@archlinux.org>
# Maintainer: guns <self@sungpae.com>

pkgname=ncdu-nerv
pkgver=
pkgrel=1
pkgdesc='Custom ncdu build'
url='http://dev.yorhel.nl/ncdu/'
license=('custom:MIT')
groups=('nerv')
depends=('ncurses')
arch=('i686' 'x86_64')
provides=('ncdu')
conflicts=('ncdu')

pkgver() {
	git describe --long --tags | tr - .
}

build() {
	cd "$startdir"
	[[ -x configure ]] || autoreconf -i
	./configure --prefix=/usr --with-open-cmd="${OPEN_CMD:-open}"
	make
}

package() {
	cd "$startdir"
	make DESTDIR="${pkgdir}" install
	install -Dm644 COPYING "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
