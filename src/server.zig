//! The dev server: HTTP for the static client, WebSocket for the app itself.
//!
//! `std.http.Server` is not used because the socket has to be hijacked for the
//! WebSocket upgrade; instead every connection is read by hand through
//! `ws.Conn`, which buffers both the HTTP request and the frames that follow it.
//!
//! Threading model: one thread per connection, and one `Session` per thread.
//! Sessions never share values, so refcounting stays non-atomic. The only shared
//! state is the current `Module`, guarded by a mutex and swapped wholesale on
//! hot reload. Retired modules stay alive until shutdown because live sessions
//! still point into their arenas.

const std = @import("std");
const builtin = @import("builtin");
const module = @import("module.zig");
const session = @import("session.zig");
const ws = @import("ws.zig");
const value = @import("value.zig");
const jsonw = @import("jsonw.zig");
const proto = @import("proto.zig");

const assets = @import("assets");

pub const index_html = assets.index_html;
pub const client_js = assets.client_js;
pub const client_css = assets.client_css;

pub const version_string = @import("build_options").version;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    reload: bool = true,
    /// Socket receive timeout; also the timer-resolution floor.
    poll_ms: u32 = 50,
    open_browser: bool = false,
    quiet: bool = false,
    color: bool = true,
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    path: []const u8,
    opts: Options,

    mtx: std.Thread.Mutex = .{},
    current: *module.Module,
    retired: std.ArrayList(*module.Module),
    generation: std.atomic.Value(u32),
    stop: std.atomic.Value(bool),
    connections: std.atomic.Value(u32),
    started_at: i64 = 0,
    /// Written by `run()` from the accept thread, read by whoever spawned it
    /// (the integration test needs the ephemeral port), hence atomic.
    bound_port: std.atomic.Value(u16),
    listening: std.atomic.Value(bool),

    pub fn init(alloc: std.mem.Allocator, path: []const u8, m: *module.Module, opts: Options) !Server {
        return .{
            .alloc = alloc,
            .path = try alloc.dupe(u8, path),
            .opts = opts,
            .current = m,
            .retired = std.ArrayList(*module.Module).init(alloc),
            .generation = std.atomic.Value(u32).init(1),
            .stop = std.atomic.Value(bool).init(false),
            .connections = std.atomic.Value(u32).init(0),
            .started_at = std.time.milliTimestamp(),
            .bound_port = std.atomic.Value(u16).init(0),
            .listening = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.retired.items) |m| m.deinit();
        self.retired.deinit();
        self.current.deinit();
        self.alloc.free(@constCast(self.path));
    }

    pub fn appModule(self: *Server) *module.Module {
        self.mtx.lock();
        defer self.mtx.unlock();
        return self.current;
    }

    pub fn requestStop(self: *Server) void {
        self.stop.store(true, .monotonic);
    }

    // -- main loop ----------------------------------------------------------

    pub fn run(self: *Server) !void {
        const addr = std.net.Address.parseIp(self.opts.host, self.opts.port) catch {
            log(self, "cannot parse address {s}:{d}", .{ self.opts.host, self.opts.port });
            return error.BadAddress;
        };
        var listener = addr.listen(.{ .reuse_address = true }) catch |e| {
            log(self, "cannot listen on {s}:{d} ({s})", .{ self.opts.host, self.opts.port, @errorName(e) });
            return e;
        };
        defer listener.deinit();

        self.bound_port.store(listener.listen_address.getPort(), .monotonic);
        self.listening.store(true, .monotonic);

        const m = self.appModule();
        log(self, "{s} {s} — serving on http://{s}:{d}", .{ m.unit.app_name, version_string, self.opts.host, self.bound_port.load(.monotonic) });
        if (self.opts.reload and !m.precompiled) {
            log(self, "watching {s} for changes", .{self.path});
        }

        var watcher: ?std.Thread = null;
        if (self.opts.reload and !m.precompiled) {
            watcher = std.Thread.spawn(.{}, reloadLoop, .{self}) catch null;
        }

        if (self.opts.open_browser) {
            var url_buf: [128]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "http://{s}:{d}/", .{ self.opts.host, self.bound_port.load(.monotonic) }) catch "http://localhost/";
            openBrowser(url);
        }

        while (!self.stop.load(.monotonic)) {
            const conn = listener.accept() catch |e| {
                if (self.stop.load(.monotonic)) break;
                log(self, "accept failed: {s}", .{@errorName(e)});
                continue;
            };
            const t = std.Thread.spawn(.{}, connectionMain, .{ self, conn.stream }) catch {
                conn.stream.close();
                continue;
            };
            t.detach();
        }

        if (watcher) |w| w.join();
        self.listening.store(false, .monotonic);
    }

    fn reloadLoop(self: *Server) void {
        while (!self.stop.load(.monotonic)) {
            std.time.sleep(200 * std.time.ns_per_ms);
            self.checkReload();
        }
    }

    fn checkReload(self: *Server) void {
        const current = self.appModule();
        const mt = module.mtimeOf(self.path) orelse return;
        if (mt == current.mtime_ns) return;

        const next = module.load(self.alloc, self.path, self.opts.color) catch |e| {
            log(self, "reload failed ({s}) — keeping the previous build", .{@errorName(e)});
            // Avoid hammering a file that stays broken: adopt its mtime.
            self.mtx.lock();
            self.current.mtime_ns = mt;
            self.mtx.unlock();
            return;
        };

        self.mtx.lock();
        const old = self.current;
        self.current = next;
        self.retired.append(old) catch {};
        self.mtx.unlock();
        _ = self.generation.fetchAdd(1, .monotonic);
        log(self, "reloaded {s} ({s})", .{ self.path, next.unit.app_name });
    }

    // -- connections --------------------------------------------------------

    fn connectionMain(self: *Server, stream: std.net.Stream) void {
        defer stream.close();
        _ = self.connections.fetchAdd(1, .monotonic);
        defer _ = self.connections.fetchSub(1, .monotonic);

        var conn = ws.Conn.init(self.alloc, stream, true);
        defer conn.deinit();
        conn.setReadTimeoutMs(self.opts.poll_ms);

        var buf: [8192]u8 = undefined;
        const request_line = conn.readLine(&buf) catch return;

        var it = std.mem.tokenizeScalar(u8, request_line, ' ');
        const method_tok = it.next() orelse return;
        const target_tok = it.next() orelse return;
        // `buf` is reused for every header line below, so the request line has
        // to be copied out before the loop clobbers it.
        const method = self.alloc.dupe(u8, method_tok) catch return;
        const target = self.alloc.dupe(u8, target_tok) catch return;
        defer self.alloc.free(method);
        defer self.alloc.free(target);

        var key: []const u8 = "";
        var upgrade = false;
        var hdr: [4096]u8 = undefined;
        while (true) {
            const line = conn.readLine(&hdr) catch return;
            if (line.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(line, "sec-websocket-key:")) {
                key = self.alloc.dupe(u8, std.mem.trim(u8, line["sec-websocket-key:".len..], " ")) catch return;
            } else if (std.ascii.startsWithIgnoreCase(line, "upgrade:")) {
                const v = std.mem.trim(u8, line["upgrade:".len..], " ");
                if (std.ascii.eqlIgnoreCase(v, "websocket")) upgrade = true;
            }
        }
        defer if (key.len > 0) self.alloc.free(@constCast(key));

        if (upgrade and key.len > 0) {
            self.serveWs(&conn, key, target);
        } else {
            self.serveHttp(&conn, method, target);
        }
    }

    fn serveHttp(self: *Server, conn: *ws.Conn, method: []const u8, target: []const u8) void {
        var route = target;
        if (std.mem.indexOfScalar(u8, route, '?')) |q| route = route[0..q];

        if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
            return sendText(conn, 405, "method not allowed");
        }
        if (route.len == 0 or std.mem.eql(u8, route, "/") or std.mem.eql(u8, route, "/index.html")) {
            return sendAsset(conn, 200, "text/html; charset=utf-8", index_html);
        }
        if (std.mem.eql(u8, route, "/client.js")) {
            return sendAsset(conn, 200, "text/javascript; charset=utf-8", client_js);
        }
        if (std.mem.eql(u8, route, "/client.css")) {
            return sendAsset(conn, 200, "text/css; charset=utf-8", client_css);
        }
        if (std.mem.eql(u8, route, "/favicon.ico")) {
            return sendAsset(conn, 204, "image/x-icon", "");
        }
        if (std.mem.eql(u8, route, "/health")) {
            var w = jsonw.Writer.init(self.alloc);
            defer w.deinit();
            const m = self.appModule();
            w.beginObj() catch return;
            w.key("ok") catch return;
            w.boolLit(true) catch return;
            w.sep() catch return;
            w.key("app") catch return;
            w.str(m.unit.app_name) catch return;
            w.sep() catch return;
            w.key("version") catch return;
            w.str(version_string) catch return;
            w.sep() catch return;
            w.key("generation") catch return;
            w.uint(self.generation.load(.monotonic)) catch return;
            w.sep() catch return;
            w.key("connections") catch return;
            w.uint(self.connections.load(.monotonic)) catch return;
            w.sep() catch return;
            w.key("uptime_ms") catch return;
            w.int(std.time.milliTimestamp() - self.started_at) catch return;
            w.endObj() catch return;
            const body = w.toOwnedSlice() catch return;
            defer self.alloc.free(body);
            return sendAsset(conn, 200, "application/json", body);
        }
        sendText(conn, 404, "not found");
    }

    fn serveWs(self: *Server, conn: *ws.Conn, key: []const u8, target: []const u8) void {
        var route = target;
        if (std.mem.indexOfScalar(u8, route, '?')) |q| route = route[0..q];
        if (!std.mem.eql(u8, route, "/ws") and !std.mem.eql(u8, route, "/")) {
            conn.writeText("{\"t\":\"error\",\"message\":\"unknown websocket path\"}") catch {};
            return;
        }
        conn.acceptUpgrade(key) catch {
            log(self, "websocket handshake failed", .{});
            return;
        };

        const m = self.appModule();
        const gen = self.generation.load(.monotonic);
        const s = session.Session.create(self.alloc, m.unit, m.path, wsSink, @ptrCast(conn)) catch {
            log(self, "out of memory creating a session", .{});
            return;
        };
        defer s.destroy();

        s.start() catch |e| {
            log(self, "session start failed: {s}", .{@errorName(e)});
            return;
        };

        while (!self.stop.load(.monotonic)) {
            if (self.generation.load(.monotonic) != gen) {
                s.sendReload() catch break;
                break;
            }
            s.tick(std.time.milliTimestamp()) catch break;

            const msg = conn.readMessage() catch |e| {
                if (e != error.Closed) log(self, "websocket error: {s}", .{@errorName(e)});
                break;
            };
            const bytes = msg orelse continue;

            const cm = proto.parseClientMsg(self.alloc, bytes);
            switch (cm) {
                // dispatch* take ownership of the payload value.
                .event => |ev| s.dispatchEvent(ev.id, ev.name, ev.args) catch |e| {
                    if (e == error.Closed) break;
                },
                .input => |in| s.dispatchInput(in.id, in.value, "input") catch |e| {
                    if (e == error.Closed) break;
                },
                .ping => s.sendPong() catch break,
                .unknown => {},
            }
        }
    }

    fn wsSink(ctx: *anyopaque, bytes: []const u8) session.SendError!void {
        const conn: *ws.Conn = @ptrCast(@alignCast(ctx));
        conn.writeText(bytes) catch return error.Closed;
    }

    fn log(self: *const Server, comptime fmt: []const u8, args: anytype) void {
        if (self.opts.quiet) return;
        const w = std.io.getStdErr().writer();
        if (self.opts.color) w.writeAll("\x1b[2m") catch {};
        w.print("weave: ", .{}) catch {};
        if (self.opts.color) w.writeAll("\x1b[0m") catch {};
        w.print(fmt ++ "\n", args) catch {};
    }
};

fn sendAsset(conn: *ws.Conn, status: u16, content_type: []const u8, body: []const u8) void {
    var head: [512]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n", .{
        status,
        statusText(status),
        content_type,
        body.len,
    }) catch return;
    conn.stream.writeAll(h) catch return;
    if (body.len > 0) conn.stream.writeAll(body) catch {};
}

fn sendText(conn: *ws.Conn, status: u16, body: []const u8) void {
    sendAsset(conn, status, "text/plain; charset=utf-8", body);
}

fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "OK",
    };
}

pub fn openBrowser(url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };
    var child = std.process.Child.init(argv, value.alloc);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    _ = child.spawn() catch return;
}
