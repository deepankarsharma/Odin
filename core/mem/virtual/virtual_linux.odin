#+build linux
#+private
package mem_virtual

import "core:sys/linux"

when .Thread in ODIN_SANITIZER_FLAGS {
	foreign import kaho_tsan_libc "system:c"
	@(default_calling_convention = "c")
	foreign kaho_tsan_libc {
		@(link_name = "mmap")
		kaho_tsan_mmap :: proc(addr: rawptr, length: uint, prot, flags, fd: i32, offset: i64) -> rawptr ---
		@(link_name = "munmap")
		kaho_tsan_munmap :: proc(addr: rawptr, length: uint) -> i32 ---
	}
}

_reserve :: proc "contextless" (size: uint, address_hint: uintptr) -> (data: []byte, err: Allocator_Error) {
	when .Thread in ODIN_SANITIZER_FLAGS {
		MAP_PRIVATE_ANONYMOUS :: 0x22
		mapped := kaho_tsan_mmap(rawptr(address_hint), size, 0, MAP_PRIVATE_ANONYMOUS, -1, 0)
		if uintptr(mapped) == ~uintptr(0) {
			return nil, .Out_Of_Memory
		}
		return (cast([^]byte)mapped)[:size], nil
	}
	addr, errno := linux.mmap(address_hint, size, {}, {.PRIVATE, .ANONYMOUS})
	if errno == .ENOMEM {
		return nil, .Out_Of_Memory
	} else if errno == .EINVAL {
		return nil, .Invalid_Argument
	}
	return (cast([^]byte)addr)[:size], nil
}

_commit :: proc "contextless" (data: rawptr, size: uint) -> Allocator_Error {
	errno := linux.mprotect(data, size, {.READ, .WRITE})
	if errno == .EINVAL {
		return .Invalid_Pointer
	} else if errno == .ENOMEM {
		return .Out_Of_Memory
	}
	return nil
}

_decommit :: proc "contextless" (data: rawptr, size: uint) {
	_ = linux.mprotect(data, size, {})
	_ = linux.madvise(data, size, .FREE)
}

_release :: proc "contextless" (data: rawptr, size: uint) {
	when .Thread in ODIN_SANITIZER_FLAGS {
		_ = kaho_tsan_munmap(data, size)
	} else {
		_ = linux.munmap(data, size)
	}
}

_protect :: proc "contextless" (data: rawptr, size: uint, flags: Protect_Flags) -> bool {
	pflags: linux.Mem_Protection
	pflags = {}
	if .Read    in flags { pflags += {.READ}  }
	if .Write   in flags { pflags += {.WRITE} }
	if .Execute in flags { pflags += {.EXEC}  }
	errno := linux.mprotect(data, size, pflags)
	return errno == .NONE
}

_map_file :: proc "contextless" (fd: uintptr, size: i64, flags: Map_File_Flags) -> (data: []byte, error: Map_File_Error) {
	prot: linux.Mem_Protection
	if .Read in flags {
		prot += {.READ}
	}
	if .Write in flags {
		prot += {.WRITE}
	}

	flags := linux.Map_Flags{.SHARED}
	addr, errno := linux.mmap(0, uint(size), prot, flags, linux.Fd(fd), offset=0)
	if addr == nil || errno != nil {
		return nil, .Map_Failure
	}
	return ([^]byte)(addr)[:size], nil
}

_unmap_file :: proc "contextless" (data: []byte) {
	_release(raw_data(data), uint(len(data)))
}
