#!/usr/bin/env sh
set -e

cc=${CC:-cc}
ar=${AR:-ar}
ODIN_ROOT=${ODIN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}

build_wasm() {
	mkdir -p ../lib
	$cc -c -Os --target=wasm32 --sysroot="$ODIN_ROOT"/vendor/libc-shim stb_image.c        -o ../lib/stb_image_wasm.o        -DSTBI_NO_STDIO
	$cc -c -Os --target=wasm32 --sysroot="$ODIN_ROOT"/vendor/libc-shim stb_image_write.c  -o ../lib/stb_image_write_wasm.o  -DSTBI_WRITE_NO_STDIO 
	$cc -c -Os --target=wasm32 --sysroot="$ODIN_ROOT"/vendor/libc-shim stb_image_resize.c -o ../lib/stb_image_resize_wasm.o
	$cc -c -Os --target=wasm32 --sysroot="$ODIN_ROOT"/vendor/libc-shim stb_truetype.c     -o ../lib/stb_truetype_wasm.o
	# Pretends to be emscripten so stb vorbis takes the right code path for including alloca.h
	$cc -c -Os --target=wasm32 --sysroot="$ODIN_ROOT"/vendor/libc-shim stb_vorbis.c       -o ../lib/stb_vorbis_wasm.o       -DSTB_VORBIS_NO_STDIO -D__EMSCRIPTEN__
	$cc -c -Os --target=wasm32 --sysroot="$ODIN_ROOT"/vendor/libc-shim stb_rect_pack.c    -o ../lib/stb_rect_pack_wasm.o
	$cc -c -Os --target=wasm32                                          stb_sprintf.c      -o ../lib/stb_sprintf_wasm.o
}

build_unix() {
	mkdir -p ../lib
	$cc -c -O2 -Os -fPIC stb_image.c stb_image_write.c stb_image_resize.c stb_truetype.c stb_rect_pack.c stb_vorbis.c stb_sprintf.c
	$ar rcs ../lib/stb_image.a        stb_image.o
	$ar rcs ../lib/stb_image_write.a  stb_image_write.o
	$ar rcs ../lib/stb_image_resize.a stb_image_resize.o
	$ar rcs ../lib/stb_truetype.a     stb_truetype.o
	$ar rcs ../lib/stb_rect_pack.a    stb_rect_pack.o
	$ar rcs ../lib/stb_vorbis.a       stb_vorbis.o
	$ar rcs ../lib/stb_sprintf.a      stb_sprintf.o
	#$cc -fPIC -shared -Wl,-soname=stb_image.so         -o ../lib/stb_image.so        stb_image.o
	#$cc -fPIC -shared -Wl,-soname=stb_image_write.so   -o ../lib/stb_image_write.so  stb_image_write.o
	#$cc -fPIC -shared -Wl,-soname=stb_image_resize.so  -o ../lib/stb_image_resize.so stb_image_resize.o
	#$cc -fPIC -shared -Wl,-soname=stb_truetype.so      -o ../lib/stb_truetype.so     stb_image_truetype.o
	#$cc -fPIC -shared -Wl,-soname=stb_rect_pack.so     -o ../lib/stb_rect_pack.so    stb_rect_packl.o
	#$cc -fPIC -shared -Wl,-soname=stb_vorbis.so        -o ../lib/stb_vorbis.so       stb_vorbisl.o
	rm *.o
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
	darwin_archive stb_image
	darwin_archive stb_image_write
	darwin_archive stb_image_resize
	darwin_archive stb_truetype
	darwin_archive stb_rect_pack
	darwin_archive stb_vorbis
	darwin_archive stb_sprintf
}

cd "$ODIN_ROOT/vendor/stb/src" || exit 1

case $1 in
wasm)
	build_wasm ;;
unix)
	build_unix ;;
darwin)
	build_darwin ;;
*)
	# Don't care about word splitting here
	if [ $(uname -s) = 'Darwin' ]; then
		build_darwin
	else
		build_unix
	fi ;;
esac
