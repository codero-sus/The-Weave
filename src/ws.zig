//! Minimal WebSocket (RFC 6455) over `std.net.Stream`.
//!
//! std has no WebSocket implementation, so the framing is hand-rolled. It
//! supports both ends of the connection: a server writes unmasked frames and
//! expects masked ones, a client does the opposite. That symmetry is what makes
//! `itest.zig` able to drive a real server over a real socket.
//!
//! Reads are expected to run with a short socket timeout (`setReadTimeoutMs`)
//! so the owning thread can wake up periodically to fire `after <ms>:` timers;
//! a timeout surfaces as `readMessage` returning `null` rather than an error.

const std = @import("std");
const builtin = @import("builtin");

const Sha1 = std.crypto.hash.Sha1;
const b64 = std.base64.standard.Encoder;

/// The handshake GUID, verbatim from RFC 6455 §1.3.
pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const op_continuation: u8 = 0x0;
pub const op_text: u8 = 0x1;
pub const op_binary: u8 = 0x2;
pub const op_close: u8 = 0x8;
pub const op_ping: u8 = 0x9;
pub const op_pong: u8 = 0xA;

pub const Error = error{ Closed, Protocol, OutOfMemory, TooLarge, Timeout };

pub fn secWebSocketAccept(key: []const u8) [b64.calcSize(Sha1.digest_length)]u8 {
    var sha = Sha1.init(.{});
    sha.update(key);
    sha.update(guid);
    var digest: [Sha1.digest_length]u8 = undefined;
    sha.final(&digest);
    var out: [b64.calcSize(Sha1.digest_length)]u8 = undefined;
    _ = b64.encode(&out, &digest);
    return out;
}

pub const Conn = struct {
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    /// True for the browser-facing side: incoming frames must be masked and
    /// outgoing frames must not be.
    server_side: bool = true,

    rbuf: [16384]u8 = undefined,
    rpos: usize = 0,
    rlen: usize = 0,
    eof: bool = false,

    /// Fragmented-message assembly. Borrowed by the caller until the next
    /// `readMessage`.
    msg: std.ArrayList(u8),
    frag_active: bool = false,
    frag_op: u8 = op_text,

    wbuf: std.ArrayList(u8),
    mask_rng: std.rand.DefaultPrng,

    /// True when the last socket read hit the receive timeout instead of data.
    timed_out: bool = false,

    max_message: usize = 8 << 20,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,

    pub fn init(a: std.mem.Allocator, stream: std.net.Stream, server_side: bool) Conn {
        return .{
            .alloc = a,
            .stream = stream,
            .server_side = server_side,
            .msg = std.ArrayList(u8).init(a),
            .wbuf = std.ArrayList(u8).init(a),
            .mask_rng = std.rand.DefaultPrng.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))),
        };
    }

    pub fn deinit(self: *Conn) void {
        self.msg.deinit();
        self.wbuf.deinit();
    }

    pub fn close(self: *Conn) void {
        self.stream.close();
        self.eof = true;
    }

    /// Arm a receive timeout so `readMessage` returns null instead of blocking
    /// forever. POSIX surfaces this as WouldBlock; Windows maps a socket read
    /// timeout to a different error, hence the wider net in `fill`.
    pub fn setReadTimeoutMs(self: *Conn, ms: u32) void {
        if (builtin.os.tag == .windows) {
            // winsock: SOL_SOCKET / SO_RCVTIMEO with a DWORD of milliseconds.
            var dw: u32 = ms;
            std.posix.setsockopt(self.stream.handle, 0xFFFF, 0x1006, std.mem.asBytes(&dw)) catch {};
            return;
        }
        // POSIX: a struct timeval. Field names differ between Linux and Darwin.
        const TV = std.posix.timeval;
        var tv: TV = undefined;
        if (comptime @hasField(TV, "tv_sec")) {
            tv.tv_sec = @intCast(ms / 1000);
            tv.tv_usec = @intCast((ms % 1000) * 1000);
        } else {
            tv.sec = @intCast(ms / 1000);
            tv.usec = @intCast((ms % 1000) * 1000);
        }
        std.posix.setsockopt(self.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    // -- buffered input -----------------------------------------------------

    fn noData(e: anyerror) bool {
        return switch (e) {
            error.WouldBlock, error.ConnectionTimedOut, error.OperationAborted => true,
            else => false,
        };
    }

    /// Pull more bytes into `rbuf`. Returns false on EOF *or* timeout; check
    /// `timed_out` to tell them apart.
    fn fillPoll(self: *Conn) Error!bool {
        self.timed_out = false;
        if (self.eof) return false;
        if (self.rpos > 0 and self.rpos == self.rlen) {
            self.rpos = 0;
            self.rlen = 0;
        }
        if (self.rlen == self.rbuf.len) return true;
        const n = self.stream.read(self.rbuf[self.rlen..]) catch |e| {
            if (noData(e)) {
                self.timed_out = true;
                return false;
            }
            return error.Closed;
        };
        if (n == 0) {
            self.eof = true;
            return false;
        }
        self.rlen += n;
        self.bytes_in += n;
        return true;
    }

    /// True when the buffer holds unread bytes.
    fn buffered(self: *const Conn) bool {
        return self.rpos < self.rlen;
    }

    pub fn readByte(self: *Conn) Error!u8 {
        while (!self.buffered()) {
            if (!(try self.fillPoll())) return if (self.timed_out) error.Timeout else error.Closed;
        }
        const b = self.rbuf[self.rpos];
        self.rpos += 1;
        return b;
    }

    pub fn readExact(self: *Conn, dst: []u8) Error!void {
        var off: usize = 0;
        while (off < dst.len) {
            if (!self.buffered()) {
                if (!(try self.fillPoll())) return if (self.timed_out) error.Timeout else error.Closed;
            }
            const avail = self.rlen - self.rpos;
            const want = dst.len - off;
            const n = @min(avail, want);
            @memcpy(dst[off .. off + n], self.rbuf[self.rpos .. self.rpos + n]);
            self.rpos += n;
            off += n;
        }
    }

    /// Read one CRLF-terminated line into `buf` (terminator stripped).
    /// Used while parsing the HTTP request, before any framing applies.
    pub fn readLine(self: *Conn, buf: []u8) Error![]u8 {
        var n: usize = 0;
        while (true) {
            const c = self.readByte() catch |e| return e;
            if (c == '\n') {
                if (n > 0 and buf[n - 1] == '\r') n -= 1;
                return buf[0..n];
            }
            if (n < buf.len) {
                buf[n] = c;
                n += 1;
            } else return error.Protocol;
        }
    }

    /// Read `n` bytes straight into an ArrayList, unmasking as we go.
    fn readPayload(self: *Conn, n: u64, mask: ?[4]u8) Error!void {
        const start = self.msg.items.len;
        if (start + n > self.max_message) return error.TooLarge;
        try self.msg.resize(start + @as(usize, @intCast(n)));
        try self.readExact(self.msg.items[start..]);
        if (mask) |k| {
            for (self.msg.items[start..], 0..) |*b, i| {
                b.* ^= k[@as(usize, @intCast(i)) % 4];
            }
        }
    }

    // -- handshake ----------------------------------------------------------

    /// Server side: answer a valid upgrade request.
    pub fn acceptUpgrade(self: *Conn, key: []const u8) !void {
        const accept = secWebSocketAccept(key);
        var head = std.ArrayList(u8).init(self.alloc);
        defer head.deinit();
        try head.writer().print(
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
        try self.stream.writeAll(head.items);
        self.bytes_out += head.items.len;
    }

    /// Client side: open the upgrade and check the server's answer.
    pub fn requestUpgrade(self: *Conn, host: []const u8, path: []const u8) !void {
        var key_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&key_raw);
        var key: [b64.calcSize(key_raw.len)]u8 = undefined;
        _ = b64.encode(&key, &key_raw);

        var head = std.ArrayList(u8).init(self.alloc);
        defer head.deinit();
        try head.writer().print(
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n\r\n",
            .{ path, host, key },
        );
        try self.stream.writeAll(head.items);

        var buf: [8192]u8 = undefined;
        const status = try self.readLine(&buf);
        if (std.mem.indexOf(u8, status, "101") == null) return error.Protocol;
        var expected: ?[]const u8 = null;
        while (true) {
            const line = try self.readLine(&buf);
            if (line.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(line, "sec-websocket-accept:")) {
                expected = std.mem.trim(u8, line["sec-websocket-accept:".len..], " ");
            }
        }
        const want = secWebSocketAccept(&key);
        if (expected == null or !std.mem.eql(u8, expected.?, &want)) return error.Protocol;
    }

    // -- framing ------------------------------------------------------------

    pub fn writeFrame(self: *Conn, opcode: u8, payload: []const u8) Error!void {
        self.wbuf.clearRetainingCapacity();
        const w = self.wbuf.writer();
        try w.writeByte(0x80 | opcode); // FIN always set: we never fragment outbound

        const mask: bool = !self.server_side;
        const len = payload.len;
        if (len < 126) {
            try w.writeByte(@as(u8, @intCast(len)) | @as(u8, if (mask) 0x80 else 0));
        } else if (len <= 0xFFFF) {
            try w.writeByte(@as(u8, 126) | @as(u8, if (mask) 0x80 else 0));
            try w.writeInt(u16, @intCast(len), .big);
        } else {
            try w.writeByte(@as(u8, 127) | @as(u8, if (mask) 0x80 else 0));
            try w.writeInt(u64, @intCast(len), .big);
        }

        var key: [4]u8 = undefined;
        if (mask) {
            self.mask_rng.random().bytes(&key);
            try w.writeAll(&key);
        }
        const head_len = self.wbuf.items.len;
        try self.wbuf.appendSlice(payload);
        if (mask) {
            for (self.wbuf.items[head_len..], 0..) |*b, i| {
                b.* ^= key[i % 4];
            }
        }

        self.stream.writeAll(self.wbuf.items) catch return error.Closed;
        self.bytes_out += self.wbuf.items.len;
    }

    pub fn writeText(self: *Conn, s: []const u8) Error!void {
        try self.writeFrame(op_text, s);
    }

    pub fn writePing(self: *Conn, payload: []const u8) Error!void {
        try self.writeFrame(op_ping, payload);
    }

    pub fn writeClose(self: *Conn, code: u16) void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        self.writeFrame(op_close, &payload) catch {};
    }

    /// Read the next complete application message.
    ///
    /// Returns `null` when the socket timed out with no frame in progress, which
    /// is the server's cue to run timers. Control frames (ping/pong/close) are
    /// handled here and never surface to the caller. A timeout *mid-frame* is
    /// fatal: partially read payloads cannot be resumed safely.
    pub fn readMessage(self: *Conn) Error!?[]const u8 {
        while (true) {
            if (!self.frag_active) self.msg.clearRetainingCapacity();

            const b0 = self.readByte() catch |e| {
                if (e == error.Timeout and !self.frag_active) return null;
                return e;
            };
            const b1 = self.readByte() catch |e| return e;
            const fin = (b0 & 0x80) != 0;
            const opcode = b0 & 0x0F;
            const masked = (b1 & 0x80) != 0;
            // RFC 6455 §5.1: a server receives *masked* frames from clients and a
            // client receives *unmasked* frames from servers.
            if (masked != self.server_side) return error.Protocol;

            var len: u64 = b1 & 0x7F;
            if (len == 126) {
                var ext: [2]u8 = undefined;
                try self.readExact(&ext);
                len = std.mem.readInt(u16, &ext, .big);
            } else if (len == 127) {
                var ext: [8]u8 = undefined;
                try self.readExact(&ext);
                len = std.mem.readInt(u64, &ext, .big);
            }
            if (len > self.max_message) return error.TooLarge;
            var mask: ?[4]u8 = null;
            if (masked) {
                var k: [4]u8 = undefined;
                try self.readExact(&k);
                mask = k;
            }

            const before = self.msg.items.len;
            try self.readPayload(len, mask);
            const chunk = self.msg.items[before..];

            switch (opcode) {
                op_ping => {
                    const saved = try self.alloc.dupe(u8, chunk);
                    defer self.alloc.free(saved);
                    self.msg.shrinkRetainingCapacity(before);
                    try self.writeFrame(op_pong, saved);
                },
                op_pong => {
                    self.msg.shrinkRetainingCapacity(before);
                },
                op_close => {
                    self.writeClose(1000);
                    self.eof = true;
                    return error.Closed;
                },
                else => {
                    if (!self.frag_active) {
                        self.frag_op = opcode;
                        self.frag_active = true;
                    } else if (opcode != op_continuation) {
                        return error.Protocol;
                    }
                    if (fin) {
                        self.frag_active = false;
                        if (self.frag_op == op_binary) return error.Protocol; // JSON only
                        return self.msg.items;
                    }
                },
            }
        }
    }
};
