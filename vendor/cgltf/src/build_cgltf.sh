#!/usr/bin/env sh
set -e

cc=${CC:-cc}
ar=${AR:-ar}
ODIN_ROOT=${ODIN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}

cd "$ODIN_ROOT/vendor/cgltf/src" || exit 1

build_wasm() {
	mkdir -p ../lib
	$cc -c -Os --target=wasm32 --sysroot="$ODIN_ROOT/vendor/libc-shim" cgltf.c -o ../lib/cgltf_wasm.o
}

build_unix() {
	mkdir -p ../lib
	$cc -c -O2 -Os -fPIC cgltf.c 	
	$ar rcs ../lib/cgltf.a        cgltf.o
	rm ./*.o
}

# Each Darwin library is a fat static archive: one ar archive per
# architecture, combined with lipo. lipo over bare objects yields a fat object
# under an .a name, which the linker loads whole every time the library
# appears on the command line, so a library listed twice failed with duplicate
# symbols. An archive contributes each member once.
darwin_archive() {
	name=$1
	for arch in x86_64 arm64; do
		$cc -arch $arch -c -O2 -Os -fPIC "$name.c" -o "$name-$arch.o" -mmacosx-version-min=11.0
		rm -f "$name-$arch.a"
		$ar rcs "$name-$arch.a" "$name-$arch.o"
	done
	lipo -create "$name-x86_64.a" "$name-arm64.a" -output "../lib/darwin/$name.a"
	rm -f "$name-x86_64.o" "$name-arm64.o" "$name-x86_64.a" "$name-arm64.a"
}

build_darwin() {
	mkdir -p ../lib/darwin
	darwin_archive cgltf
}

case $1 in
wasm)
	build_wasm ;;
unix)
	build_unix ;;
darwin)
	build_darwin ;;
*)
	if [ "$(uname -s)" = 'Darwin' ]; then
		build_darwin
	else
		build_unix
	fi ;;
esac
