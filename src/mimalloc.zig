//! mimalloc Zig Allocator 래퍼
//!
//! Microsoft mimalloc (v3.2.8)을 Zig의 std.mem.Allocator 인터페이스로 래핑한다.
//! ReleaseFast/ReleaseSafe에서 GPA/c_allocator 대신 사용하여
//! 스레드별 힙 격리, 페이지 캐싱, 슬랩 할당의 이점을 얻는다.

const std = @import("std");

// mimalloc C API extern 선언
extern "c" fn mi_malloc(size: usize) ?*anyopaque;
extern "c" fn mi_malloc_aligned(size: usize, alignment: usize) ?*anyopaque;
extern "c" fn mi_realloc(p: ?*anyopaque, newsize: usize) ?*anyopaque;
extern "c" fn mi_free(p: ?*anyopaque) void;
extern "c" fn mi_usable_size(p: ?*const anyopaque) usize;

fn allocFn(_: *anyopaque, n: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const al = alignment.toByteUnits();
    const ptr = if (al <= @as(usize, @alignOf(*anyopaque)))
        mi_malloc(n)
    else
        mi_malloc_aligned(n, al);
    return @as(?[*]u8, @ptrCast(ptr));
}

fn resizeFn(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // mimalloc은 in-place resize를 지원하지만, usable_size 내에서만 가능
    if (new_len <= mi_usable_size(buf.ptr)) return true;
    return false;
}

fn remapFn(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    _ = alignment;
    const ptr = mi_realloc(buf.ptr, new_len);
    return @as(?[*]u8, @ptrCast(ptr));
}

fn freeFn(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    mi_free(buf.ptr);
}

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &vtable,
};

const vtable = std.mem.Allocator.VTable{
    .alloc = allocFn,
    .resize = resizeFn,
    .free = freeFn,
    .remap = remapFn,
};
