package test_core_mem

import "base:runtime"
import "base:sanitizer"
import "core:mem"
import "core:mem/virtual"
import "core:testing"

// Under AddressSanitizer each allocator that hands out pieces of a larger buffer marks exactly the
// bytes it handed out addressable: the byte after a piece is poisoned, whatever its size, and so
// is a piece once it is freed, rolled back, reset or moved by a resize. Without ASan these tests
// only exercise the allocators' layouts.

@(private = "file")
SIZES :: [?]int{1, 7, 8, 9, 13, 16, 31, 64, 100, 4093}

@(private = "file")
expect_handed_out :: proc(t: ^testing.T, b: []byte, loc := #caller_location) {
	testing.expect(t, sanitizer.address_region_is_poisoned(b) == nil, "bytes handed out are poisoned", loc = loc)
	when sanitizer.ADDRESS_SANITIZER {
		after := rawptr(uintptr(raw_data(b)) + uintptr(len(b)))
		testing.expect(t, sanitizer.address_is_poisoned(after), "the byte after a piece is addressable", loc = loc)
	}
}

@(private = "file")
expect_dead :: proc(t: ^testing.T, b: []byte, loc := #caller_location) {
	when sanitizer.ADDRESS_SANITIZER {
		for k in 0 ..< len(b) {
			if !sanitizer.address_is_poisoned(&b[k]) {
				testing.expectf(t, false, "byte %d of %d freed bytes is addressable", k, len(b), loc = loc)
				return
			}
		}
	}
}

// Every size, back to back: each piece addressable, its next byte not, and writing all of one
// never touching another.
@(private = "file")
check_pieces :: proc(t: ^testing.T, allocator: runtime.Allocator, loc := #caller_location) -> (pieces: [len(SIZES)][]byte) {
	for size, k in SIZES {
		b, err := runtime.mem_alloc(size, 1, allocator)
		testing.expect_value(t, err, nil, loc)
		expect_handed_out(t, b, loc)
		runtime.memset(raw_data(b), i32(k + 1), size)
		pieces[k] = b
	}
	// With every piece handed out, each one's next byte is still a redzone, not its neighbor, and
	// so is the byte before each but the first: a piece starts on a granule, so none of the
	// redzone before it shares the piece's first granule.
	for b, k in pieces {
		expect_handed_out(t, b, loc)
		when sanitizer.ADDRESS_SANITIZER {
			before := rawptr(uintptr(raw_data(b)) - 1)
			testing.expect(t, k == 0 || sanitizer.address_is_poisoned(before), "the byte before a piece is addressable", loc = loc)
		}
		for v in b {
			if v != u8(k + 1) {
				testing.expectf(t, false, "piece %d was overwritten", k, loc = loc)
				break
			}
		}
	}
	return
}

@(test)
test_asan_runtime_arena :: proc(t: ^testing.T) {
	arena: runtime.Arena
	// A first block that holds every piece: a block's first piece follows its header.
	testing.expect_value(t, runtime.arena_init(&arena, 64 * 1024, runtime.heap_allocator()), nil)
	defer runtime.arena_destroy(&arena)
	allocator := runtime.arena_allocator(&arena)

	temp := runtime.arena_temp_begin(&arena)
	pieces := check_pieces(t, allocator)
	runtime.arena_temp_end(temp)
	for piece in pieces {
		expect_dead(t, piece)
	}

	// Grown in place, shrunk in place, then moved.
	b, _ := runtime.mem_alloc(20, 8, allocator)
	g, _ := runtime.mem_resize(raw_data(b), 20, 40, 8, allocator)
	testing.expect(t, raw_data(g) == raw_data(b))
	expect_handed_out(t, g)
	s, _ := runtime.mem_resize(raw_data(g), 40, 10, 8, allocator)
	expect_handed_out(t, s)
	expect_dead(t, g[10:])
	_, _ = runtime.mem_alloc(1, 1, allocator)
	m, _ := runtime.mem_resize(raw_data(s), 10, 5000, 8, allocator)
	expect_handed_out(t, m)
	expect_dead(t, s)

	f, _ := runtime.mem_alloc(24, 8, allocator)
	runtime.mem_free_with_size(raw_data(f), 24, allocator)
	expect_dead(t, f)

	runtime.arena_free_all(&arena)
	expect_dead(t, m)
}

@(test)
test_asan_rollback_stack :: proc(t: ^testing.T) {
	stack: mem.Rollback_Stack
	// Blocks that hold every piece, so each freed one stays the stack's.
	testing.expect_value(t, mem.rollback_stack_init(&stack, 16 * 1024, runtime.heap_allocator()), nil)
	defer mem.rollback_stack_destroy(&stack)
	allocator := mem.rollback_stack_allocator(&stack)

	pieces := check_pieces(t, allocator)
	// Freed with their sizes, out of order: poisoned at once.
	mem.free_bytes(pieces[2], allocator)
	expect_dead(t, pieces[2])
	for k := len(pieces) - 1; k >= 0; k -= 1 {
		if k != 2 {
			mem.free_bytes(pieces[k], allocator)
			expect_dead(t, pieces[k])
		}
	}

	// The last piece grown and shrunk in place, then moved by a resize.
	b, _ := runtime.mem_alloc(20, 8, allocator)
	g, _ := runtime.mem_resize(raw_data(b), 20, 60, 8, allocator)
	expect_handed_out(t, g)
	s, _ := runtime.mem_resize(raw_data(g), 60, 12, 8, allocator)
	expect_handed_out(t, s)
	expect_dead(t, g[12:])
	_, _ = runtime.mem_alloc(1, 1, allocator)
	m, _ := runtime.mem_resize(raw_data(s), 12, 200, 8, allocator)
	expect_handed_out(t, m)
	expect_dead(t, s)

	// A piece too large for a block gets a block of its own. Freeing it hands that block back to
	// the heap, which decides whether the bytes are poisoned: ASan's heap does, HeapFree does not.
	big, _ := runtime.mem_alloc(32 * 1024, 8, allocator)
	expect_handed_out(t, big)
	mem.free_bytes(big, allocator)

	mem.free_all(allocator)
	expect_dead(t, m)
}

@(test)
test_asan_rollback_stack_buffered :: proc(t: ^testing.T) {
	buffer: [16 * 1024]byte
	stack: mem.Rollback_Stack
	mem.rollback_stack_init(&stack, buffer[:])
	allocator := mem.rollback_stack_allocator(&stack)
	pieces := check_pieces(t, allocator)
	_ = pieces
	mem.rollback_stack_destroy(&stack)
	// The caller's buffer is theirs again.
	testing.expect(t, sanitizer.address_region_is_poisoned(buffer[:]) == nil)
}

@(test)
test_asan_mem_arena :: proc(t: ^testing.T) {
	buffer := make([]byte, 64 * 1024)
	defer delete(buffer)
	arena: mem.Arena
	mem.arena_init(&arena, buffer)
	allocator := mem.arena_allocator(&arena)

	temp := mem.begin_arena_temp_memory(&arena)
	pieces := check_pieces(t, allocator)
	mem.end_arena_temp_memory(temp)
	for piece in pieces {
		expect_dead(t, piece)
	}

	// A resize moves, and leaves the old bytes dead.
	b, _ := runtime.mem_alloc(20, 8, allocator)
	m, _ := runtime.mem_resize(raw_data(b), 20, 80, 8, allocator)
	expect_handed_out(t, m)
	expect_dead(t, b)

	mem.free_all(allocator)
	expect_dead(t, m)
}

@(test)
test_asan_dynamic_arena :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, block_size = 8192, out_band_size = 6000)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	pieces := check_pieces(t, allocator)

	// Shrunk in place, then moved by a resize.
	b, _ := runtime.mem_alloc(40, 8, allocator)
	s, _ := runtime.mem_resize(raw_data(b), 40, 12, 8, allocator)
	expect_handed_out(t, s)
	expect_dead(t, b[12:])
	m, _ := runtime.mem_resize(raw_data(s), 12, 300, 8, allocator)
	expect_handed_out(t, m)
	expect_dead(t, s)

	// A piece too large for a redzone in a block still fits.
	whole, err := runtime.mem_alloc(5990, 8, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(whole), 5990)

	mem.dynamic_arena_reset(&arena)
	for piece in pieces {
		if len(piece) < 6000 {
			expect_dead(t, piece)
		}
	}
	expect_dead(t, m)
	expect_dead(t, whole)
}

@(private = "file")
check_virtual_arena :: proc(t: ^testing.T, arena: ^virtual.Arena, loc := #caller_location) {
	allocator := virtual.arena_allocator(arena)

	temp := virtual.arena_temp_begin(arena)
	pieces := check_pieces(t, allocator, loc)
	virtual.arena_temp_end(temp)
	for piece in pieces {
		expect_dead(t, piece, loc)
	}

	// Grown in place, shrunk in place, then moved; and freed.
	b, _ := runtime.mem_alloc(20, 8, allocator)
	g, _ := runtime.mem_resize(raw_data(b), 20, 40, 8, allocator)
	testing.expect(t, raw_data(g) == raw_data(b), "grown in place", loc = loc)
	expect_handed_out(t, g, loc)
	s, _ := runtime.mem_resize(raw_data(g), 40, 10, 8, allocator)
	expect_handed_out(t, s, loc)
	expect_dead(t, g[10:], loc)
	_, _ = runtime.mem_alloc(1, 1, allocator)
	m, _ := runtime.mem_resize(raw_data(s), 10, 3000, 8, allocator)
	expect_handed_out(t, m, loc)
	expect_dead(t, s, loc)
	f, _ := runtime.mem_alloc(24, 8, allocator)
	mem.free_bytes(f, allocator)
	expect_dead(t, f, loc)

	// Past the first commit, so new memory is committed (and poisoned) as the arena grows.
	big, _ := runtime.mem_alloc(3 * mem.Megabyte, 8, allocator)
	expect_handed_out(t, big, loc)

	virtual.arena_free_all(arena)
	expect_dead(t, m, loc)
}

@(test)
test_asan_virtual_arena_growing :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	check_virtual_arena(t, &arena)
}

@(test)
test_asan_virtual_arena_static :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_static(&arena, reserved = 64 * mem.Megabyte), nil)
	defer virtual.arena_destroy(&arena)
	check_virtual_arena(t, &arena)
}

@(test)
test_asan_virtual_arena_buffer :: proc(t: ^testing.T) {
	buffer := make([]byte, 4 * mem.Megabyte)
	defer delete(buffer)
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_buffer(&arena, buffer), nil)
	check_virtual_arena(t, &arena)
	virtual.arena_destroy(&arena)
	// The caller's buffer is theirs again.
	testing.expect(t, sanitizer.address_region_is_poisoned(buffer) == nil)
}
