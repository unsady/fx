const std = @import("std");
const builtin = @import("builtin");

/// Load the platform CA bundle, falling back to the macOS PEM bundle when a
/// sandbox prevents reading the system keychain. Safe for concurrent requests.
pub fn prepare(client: *std.http.Client) std.http.Client.RequestError!void {
    if (comptime builtin.os.tag != .macos or std.http.Client.disable_tls) return;
    const io = client.io;
    {
        try client.ca_bundle_lock.lockShared(io);
        defer client.ca_bundle_lock.unlockShared(io);
        if (client.now != null) return;
    }

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    load(&bundle, client.allocator, io, now) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.CertificateBundleLoadFailure,
    };

    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    if (client.now != null) return;
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

pub fn load(bundle: *std.crypto.Certificate.Bundle, alloc: std.mem.Allocator, io: std.Io, now: std.Io.Timestamp) !void {
    bundle.rescan(alloc, io, now) catch |err| {
        if (builtin.os.tag == .macos and (err == error.AccessDenied or err == error.PermissionDenied)) {
            bundle.deinit(alloc);
            bundle.* = .empty;
            return loadPem(bundle, alloc, io, now, "/etc/ssl/cert.pem");
        }
        return err;
    };
}

fn loadPem(bundle: *std.crypto.Certificate.Bundle, alloc: std.mem.Allocator, io: std.Io, now: std.Io.Timestamp, path: []const u8) std.http.Client.RequestError!void {
    bundle.addCertsFromFilePathAbsolute(alloc, io, now, path) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.CertificateBundleLoadFailure,
    };
    if (bundle.map.count() == 0) return error.CertificateBundleLoadFailure;
}

test "macOS loads a nonempty CA bundle" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();

    try prepare(&client);
    try std.testing.expect(client.now != null);
    try std.testing.expect(client.ca_bundle.map.count() > 0);
}

test "PEM fallback rejects missing and empty files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const now = std.Io.Clock.real.now(io);
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.pem", .data = "" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(io, "empty.pem", &path_buffer);
    const path = path_buffer[0..path_len];

    try std.testing.expectError(error.CertificateBundleLoadFailure, loadPem(&bundle, alloc, io, now, path));
    try std.testing.expectError(error.CertificateBundleLoadFailure, loadPem(&bundle, alloc, io, now, "/nonexistent-fx-ca-bundle.pem"));
}

pub fn request(client: *std.http.Client, method: std.http.Method, uri: std.Uri, options: std.http.Client.RequestOptions) std.http.Client.RequestError!std.http.Client.Request {
    if (std.http.Client.Protocol.fromUri(uri) == .tls) try prepare(client);
    return client.request(method, uri, options);
}

pub fn fetch(client: *std.http.Client, options: std.http.Client.FetchOptions) std.http.Client.FetchError!std.http.Client.FetchResult {
    const uri = switch (options.location) {
        .url => |url| try std.Uri.parse(url),
        .uri => |uri| uri,
    };
    if (std.http.Client.Protocol.fromUri(uri) == .tls) try prepare(client);
    return client.fetch(options);
}
