//! Streaming reader for decompressing zstd data with hash verification
//!
//! This module provides a reader that decompresses zstd-compressed data streams while
//! simultaneously computing and verifying BLAKE3 hashes for data integrity.

const std = @import("std");
const c = @cImport({
    @cDefine("ZSTD_STATIC_LINKING_ONLY", "1");
    @cInclude("zstd.h");
});

/// A reader that decompresses zstd data and verifies hash incrementally
pub const DecompressingHashReader = struct {
    allocator_ptr: *std.mem.Allocator,
    dctx: *c.ZSTD_DCtx,
    hasher: std.crypto.hash.Blake3,
    input_reader: *std.Io.Reader,
    expected_hash: [32]u8,
    in_buffer: []u8,
    out_buffer: []u8,
    out_pos: usize,
    out_end: usize,
    finished: bool,
    hash_verified: bool,
    interface: std.Io.Reader,

    const Self = @This();
    const Error = error{
        DecompressionFailed,
        UnexpectedEndOfStream,
        HashMismatch,
    } || std.mem.Allocator.Error;

    pub fn init(
        allocator_ptr: *std.mem.Allocator,
        input_reader: *std.Io.Reader,
        expected_hash: [32]u8,
        allocForZstd: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
        freeForZstd: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    ) !Self {
        const custom_mem = c.ZSTD_customMem{
            .customAlloc = allocForZstd,
            .customFree = freeForZstd,
            .@"opaque" = @ptrCast(allocator_ptr),
        };

        const dctx = c.ZSTD_createDCtx_advanced(custom_mem) orelse return std.mem.Allocator.Error.OutOfMemory;
        errdefer _ = c.ZSTD_freeDCtx(dctx);

        const in_buffer_size = c.ZSTD_DStreamInSize();
        const in_buffer = try allocator_ptr.alloc(u8, in_buffer_size);
        errdefer allocator_ptr.free(in_buffer);

        const out_buffer_size = c.ZSTD_DStreamOutSize();
        const out_buffer = try allocator_ptr.alloc(u8, out_buffer_size);
        errdefer allocator_ptr.free(out_buffer);

        var result = Self{
            .allocator_ptr = allocator_ptr,
            .dctx = dctx,
            .hasher = std.crypto.hash.Blake3.init(.{}),
            .input_reader = input_reader,
            .expected_hash = expected_hash,
            .in_buffer = in_buffer,
            .out_buffer = out_buffer,
            .out_pos = 0,
            .out_end = 0,
            .finished = false,
            .hash_verified = false,
            .interface = undefined,
        };
        result.interface = .{
            .vtable = &.{
                .stream = stream,
                .discard = discard,
            },
            .buffer = &.{}, // No buffer needed, we have internal buffering
            .seek = 0,
            .end = 0,
        };
        return result;
    }

    pub fn deinit(self: *Self) void {
        _ = c.ZSTD_freeDCtx(self.dctx);
        self.allocator_ptr.free(self.in_buffer);
        self.allocator_ptr.free(self.out_buffer);
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Self = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = self.read(dest) catch |err| switch (err) {
            error.DecompressionFailed, error.HashMismatch => return std.Io.Reader.StreamError.ReadFailed,
            error.UnexpectedEndOfStream => return std.Io.Reader.StreamError.EndOfStream,
            error.OutOfMemory => return std.Io.Reader.StreamError.ReadFailed,
        };
        if (n == 0) {
            return std.Io.Reader.StreamError.EndOfStream;
        }
        w.advance(n);
        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *Self = @alignCast(@fieldParentPtr("interface", r));

        var total: usize = 0;
        var remaining: ?usize = limit.toInt();

        // Consume any buffered output data first.
        if (self.out_pos < self.out_end) {
            const available = self.out_end - self.out_pos;
            const to_consume = if (remaining) |rem| @min(available, rem) else available;
            self.out_pos += to_consume;
            total += to_consume;
            if (remaining) |*rem| {
                rem.* -= to_consume;
                if (rem.* == 0) return total;
            }
        }

        var discard_buffer: [4096]u8 = undefined;

        while (true) {
            if (remaining) |rem| {
                if (rem == 0) break;
            }

            const chunk_len = if (remaining) |rem| @min(discard_buffer.len, rem) else discard_buffer.len;
            const n = self.read(discard_buffer[0..chunk_len]) catch |err| switch (err) {
                error.DecompressionFailed, error.HashMismatch => return std.Io.Reader.Error.ReadFailed,
                error.UnexpectedEndOfStream => return std.Io.Reader.Error.EndOfStream,
                error.OutOfMemory => return std.Io.Reader.Error.ReadFailed,
            };

            if (n == 0) break;

            total += n;
            if (remaining) |*rem| {
                rem.* -= n;
                if (rem.* == 0) break;
            }
        }

        return total;
    }

    pub fn read(self: *Self, dest: []u8) Error!usize {
        if (dest.len == 0) return 0;

        var total_read: usize = 0;

        while (total_read < dest.len) {
            // If we have data in the output buffer, copy it
            if (self.out_pos < self.out_end) {
                const available = self.out_end - self.out_pos;
                const to_copy = @min(available, dest.len - total_read);
                @memcpy(dest[total_read..][0..to_copy], self.out_buffer[self.out_pos..][0..to_copy]);
                self.out_pos += to_copy;
                total_read += to_copy;

                if (total_read == dest.len) {
                    return total_read;
                }
            }

            // If finished and no more data in buffer, we're done
            if (self.finished) {
                break;
            }

            // Read more compressed data using a fixed writer
            var in_writer = std.Io.Writer.fixed(self.in_buffer);
            var reached_end = false;
            const bytes_read = self.input_reader.stream(&in_writer, std.Io.Limit.limited(self.in_buffer.len)) catch |err| switch (err) {
                error.EndOfStream => blk: {
                    reached_end = true;
                    break :blk 0;
                },
                error.ReadFailed => return error.UnexpectedEndOfStream,
                error.WriteFailed => unreachable, // fixed buffer writer doesn't fail
            };

            if (bytes_read == 0) {
                if (reached_end) {
                    if (!self.hash_verified) {
                        var actual_hash: [32]u8 = undefined;
                        self.hasher.final(&actual_hash);
                        if (!std.mem.eql(u8, &actual_hash, &self.expected_hash)) {
                            return error.HashMismatch;
                        }
                        self.hash_verified = true;
                    }
                    self.finished = true;
                    break;
                }

                if (total_read > 0) {
                    break;
                }
                continue;
            }

            // Update hash with compressed data
            self.hasher.update(self.in_buffer[0..bytes_read]);

            // Decompress
            var in_buf = c.ZSTD_inBuffer{ .src = self.in_buffer.ptr, .size = bytes_read, .pos = 0 };

            while (in_buf.pos < in_buf.size) {
                var out_buf = c.ZSTD_outBuffer{ .dst = self.out_buffer.ptr, .size = self.out_buffer.len, .pos = 0 };

                const result = c.ZSTD_decompressStream(self.dctx, &out_buf, &in_buf);
                if (c.ZSTD_isError(result) != 0) {
                    return error.DecompressionFailed;
                }

                if (out_buf.pos > 0) {
                    self.out_pos = 0;
                    self.out_end = out_buf.pos;

                    // Copy what we can to dest
                    const to_copy = @min(out_buf.pos, dest.len - total_read);
                    @memcpy(dest[total_read..][0..to_copy], self.out_buffer[0..to_copy]);
                    self.out_pos = to_copy;
                    total_read += to_copy;

                    if (total_read == dest.len) {
                        return total_read;
                    }
                }

                // If decompression is complete
                if (result == 0) {
                    break;
                }
            }
        }

        return total_read;
    }

    pub fn verifyComplete(self: *Self) !void {
        // Read any remaining data to ensure we process the entire stream
        var discard_buffer: [1024]u8 = undefined;
        while (true) {
            const n = try self.read(&discard_buffer);
            if (n == 0) break;
        }

        // The hash should have been verified during reading
        if (!self.hash_verified) {
            return error.HashMismatch;
        }
    }
};
