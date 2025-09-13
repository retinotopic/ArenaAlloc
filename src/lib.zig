const std = @import("std");
const mem = std.mem;
const dbg = std.debug;
const tst = std.testing;

const Allocator = std.mem.Allocator;
const PageAllocator = std.heap.PageAllocator;

pub const ChunkInfo = struct {
    prev_chunk: ?[]u8 = null, // 2x usize
    last_index: usize = 0,
};

pub const DebugInfo = struct {
    curridx: ?*usize = null,
    chunkcount: ?*usize = null,
    expected_align: ?*bool = null,
};

pub fn ArenaAllocator(size_of_chunk: usize, comptime istest: bool) type {
    return struct {
        const Self = @This();

        var chunk_size: usize = size_of_chunk;
        var chunkinfo: ?*ChunkInfo = null;

        // first 3x usize bytes for previous start address of slice and last index
        var curr_idx: usize = @sizeOf(ChunkInfo);
        var curr_chunk: ?[]u8 = null;
        var chunk_count: usize = 0;
        var expected_align: bool = true; // for debug/testing

        pub fn debuginfo(_: *Self) DebugInfo {
            return DebugInfo{
                .curridx = &curr_idx,
                .chunkcount = &chunk_count,
                .expected_align = &expected_align,
            };
        }
        fn alignusize(n: usize, alignment: mem.Alignment) usize {
            const alignnum = mem.Alignment.toByteUnits(alignment);
            
            var rem = @mod(n, alignnum);
            if (rem == 0) {
                rem = alignnum;
            }
            const res = n + (alignnum - rem);
            
            if (comptime istest) {
                expected_align = mem.isAligned(res, alignnum);
            }
            
            return res;
        }

        fn alloc(context: *anyopaque, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
            _ = context;
            _ = ra;
            var aligned_idx = alignusize(curr_idx, alignment);
            var aligned_size = alignusize(n, alignment);

            if (curr_chunk != null and aligned_idx + aligned_size < chunk_size) {
                curr_idx = aligned_idx + aligned_size;
                if (comptime istest) {
                    dbg.print("|ENOUGH {any} {any} |\n", .{ aligned_idx, curr_idx });
                }
                return curr_chunk.?[aligned_idx..curr_idx].ptr;
            } else {
                const slc = PageAllocator.map(chunk_size, mem.Alignment.@"1");
                if (slc == null) {
                    return null;
                }
                var chunk_new: *ChunkInfo = @ptrCast(@alignCast(&slc.?[0]));
                chunk_new.last_index = curr_idx;
                chunk_new.prev_chunk = curr_chunk;
                curr_chunk = slc.?[0..chunk_size];
                curr_idx = @sizeOf(usize) * 3;
                aligned_idx = alignusize(curr_idx, alignment);
                aligned_size = alignusize(n, alignment);
                curr_idx = aligned_idx + aligned_size;
                if (comptime istest) {
                    dbg.print("|NOT ENOUGH {any} {any} |\n", .{ aligned_idx, curr_idx });
                    chunk_count += 1;
                }
                return slc.?[aligned_idx..curr_idx].ptr;
            }
        }

        fn free(context: *anyopaque, memory: []u8, alignment: mem.Alignment, return_address: usize) void {
            _ = context;
            _ = alignment;
            _ = return_address;
            if (&curr_chunk.?[curr_idx - memory.len] == &memory[0]) {
                if (comptime istest) {
                    dbg.print("|REDUCED {any} {any}  |\n", .{ curr_idx, curr_idx - memory.len });
                }
                curr_idx = curr_idx - memory.len;
                if (curr_idx == @sizeOf(ChunkInfo)) {
                    const chunk_old: *ChunkInfo = @ptrCast(@alignCast(&curr_chunk.?[0]));
                    const unmap_chunk = curr_chunk.?;
                    curr_chunk = chunk_old.prev_chunk;
                    curr_idx = chunk_old.last_index;
                    PageAllocator.unmap(@alignCast(unmap_chunk));
                    if (comptime istest) {
                        chunk_count -= 1;
                        dbg.print("|FREE {any}  |\n", .{curr_idx});
                    }
                }
            } 
        }

        fn resize(
            context: *anyopaque,
            memory: []u8,
            alignment: mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            _ = context;
            _ = alignment;
            _ = return_address;
            _ = memory;
            _ = new_len;
            return false;
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            _ = context;
            _ = alignment;
            _ = return_address;
            _ = memory;
            _ = new_len;
            return null;
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }
    };
}
test "AllocTest" {
    const MyArenaAllocator = ArenaAllocator(150,true);
    var alloc = MyArenaAllocator{};
    const al = alloc.allocator();
    const di = alloc.debuginfo();

    const wrapval = al.alloc(u64, 10);
    try tst.expect(di.expected_align.?.*);
    dbg.print("DBG {any} {any} \n", .{ di.curridx.?.*, di.chunkcount.?.* });
    if (wrapval) |v| {
        for (0..v.len) |i| {
            dbg.print("{any} \n", .{@intFromPtr(&v[i])});
        }
    } else |err| {
        dbg.print("{any}", .{err});
    }
    var uu: []u64 = undefined;
    
    const wrapval2 = al.alloc(u64, 10);
    try tst.expect(di.expected_align.?.*);
    dbg.print("DBG {any} {any} \n", .{ di.curridx.?.*, di.chunkcount.?.* });
    if (wrapval2) |v| {
        for (0..v.len) |i| {
            dbg.print("{any} \n", .{@intFromPtr(&v[i])});
        }
        uu = v;
    } else |err| {
        dbg.print("{any}", .{err});
    }

    al.free(uu);
    try tst.expect(di.expected_align.?.*);

    const wrapval3 = al.alloc(u16, 2);
    try tst.expect(di.expected_align.?.*);
    dbg.print("DBG {any} {any} \n", .{ di.curridx.?.*, di.chunkcount.?.* });
    if (wrapval3) |v| {
        for (0..v.len) |i| {
            dbg.print("{any} \n", .{@intFromPtr(&v[i])});
        }
    } else |err| {
        dbg.print("{any}", .{err});
    }
    const wrapval4 = al.alloc(u128, 10);
    try tst.expect(di.expected_align.?.*);
    dbg.print("DBG {any} {any} \n", .{ di.curridx.?.*, di.chunkcount.?.* });
    if (wrapval4) |v| {
        for (0..v.len) |i| {
            dbg.print("{any} \n", .{@intFromPtr(&v[i])});
        }
    } else |err| {
        dbg.print("{any}", .{err});
    }
    var uu2: []u128 = undefined;

    const wrapval5 = al.alloc(u128, 10);
    try tst.expect(di.expected_align.?.*);
    dbg.print("DBG {any} {any} \n", .{ di.curridx.?.*, di.chunkcount.?.* });
    if (wrapval5) |v| {
        for (0..v.len) |i| {
            dbg.print("{any} \n", .{@intFromPtr(&v[i])});
        }
        uu2 = v;
    } else |err| {
        dbg.print("{any}", .{err});
    }

    al.free(uu2);
    try tst.expect(di.expected_align.?.*);

    const wrapval6 = al.alloc(u16, 2);
    try tst.expect(di.expected_align.?.*);
    dbg.print("DBG {any} {any} \n", .{ di.curridx.?.*, di.chunkcount.?.* });
    if (wrapval6) |v| {
        for (0..v.len) |i| {
            dbg.print("{any} \n", .{@intFromPtr(&v[i])});
        }
    } else |err| {
        dbg.print("{any}", .{err});
    }
}
