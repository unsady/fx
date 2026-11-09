//! API keys for configured providers, saved by `fx login <name>`. Each key is
//! a private file, `~/.fx/provider-keys/<name>`, in a private folder. A key in
//! the provider's environment variable takes precedence, so a saved key only
//! fills in when the variable is unset.
//!
//! The keys live in files on every platform, not the macOS Keychain: a fx
//! running in a sandbox that denies Keychain access still needs them.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const configured_provider = @import("../config/configured_provider.zig");
const secret = @import("secret.zig");
const Allocator = std.mem.Allocator;

const dir_name = "provider-keys";
pub const max_key_bytes = 8 * 1024;

pub const LoadError = Allocator.Error || error{ StoredKeyInsecure, StoredKeyUnreadable };
pub const StoreError = Allocator.Error || error{ InvalidProviderKey, StoredKeyWriteFailed };
pub const DeleteError = error{StoredKeyDeleteFailed};

pub const Deletion = enum { deleted, missing };

/// The saved key for provider `name`, or null when none is saved. Caller owns
/// the result and frees it with `secret.zeroAndFree`.
pub fn load(alloc: Allocator, name: []const u8) LoadError!?[]u8 {
    if (configured_provider.validate_id(name)) |_| {} else |_| return null;
    var dir = (openDir(false) catch |err| return unreadable("open", err)) orelse return null;
    defer dir.close();
    return loadFrom(alloc, dir.dir, name);
}

/// Saves `key` for provider `name`, replacing any saved key. Borrows `key`.
pub fn store(alloc: Allocator, name: []const u8, key: []const u8) StoreError!void {
    configured_provider.validate_id(name) catch return error.InvalidProviderKey;
    try validateKey(key);
    var dir = (openDir(true) catch |err| return writeFailed("open", err)).?;
    defer dir.close();
    return storeIn(alloc, &dir, name, key);
}

/// Deletes the saved key for provider `name`.
pub fn delete(name: []const u8) DeleteError!Deletion {
    configured_provider.validate_id(name) catch return .missing;
    var dir = (openDir(false) catch return error.StoredKeyDeleteFailed) orelse return .missing;
    defer dir.close();
    return deleteIn(dir.dir, name);
}

/// A key is one line of printable ASCII, as every provider's keys are, so a
/// pasted key with a stray space or a second line is rejected rather than
/// sent as a broken Authorization header.
pub fn validateKey(key: []const u8) error{InvalidProviderKey}!void {
    if (key.len == 0 or key.len > max_key_bytes) return error.InvalidProviderKey;
    for (key) |byte| {
        if (byte <= ' ' or byte >= 0x7f) return error.InvalidProviderKey;
    }
}

/// The profile's key folder, created when `create` is set, else null when
/// it does not exist yet.
fn openDir(create: bool) !?io_mod.VerifiedDir {
    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }),
    };
    defer home_dir.close();
    if (!create) {
        var profile = (try io_mod.openVerifiedPrivateDirIfPresent(&home_dir, profile_paths.rootName())) orelse return null;
        defer profile.close();
        return io_mod.openVerifiedPrivateDirIfPresent(&profile, dir_name);
    }
    var profile = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.rootName());
    defer profile.close();
    return try io_mod.openOrCreateVerifiedPrivateDir(&profile, dir_name);
}

fn loadFrom(alloc: Allocator, dir: std.Io.Dir, name: []const u8) LoadError!?[]u8 {
    var file = io_mod.openExistingRegularFile(dir, name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return unreadable("open_file", err),
    };
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch |err| return unreadable("stat", err);
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("provider_keys", "load refused provider={s} reason=insecure", .{name});
        return error.StoredKeyInsecure;
    }
    const bytes = io_mod.readFileToEnd(alloc, &file, max_key_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return unreadable("read", err),
    };
    validateKey(bytes) catch {
        secret.zeroAndFree(alloc, bytes);
        return unreadable("validate", error.InvalidProviderKey);
    };
    return bytes;
}

/// `durableReplaceVerified` creates the file at 0600, so the mode `loadFrom`
/// requires is enforced rather than assumed.
fn storeIn(alloc: Allocator, dir: *io_mod.VerifiedDir, name: []const u8, key: []const u8) StoreError!void {
    io_mod.durableReplaceVerified(alloc, dir, name, key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return writeFailed("replace", err),
    };
}

fn deleteIn(dir: std.Io.Dir, name: []const u8) DeleteError!Deletion {
    dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => {
            debug_trace.logf("provider_keys", "delete failed provider={s} err={s}", .{ name, @errorName(err) });
            return error.StoredKeyDeleteFailed;
        },
    };
    const ops: io_mod.DurableOps = .{};
    ops.sync_dir(ops.ctx, dir) catch return error.StoredKeyDeleteFailed;
    return .deleted;
}

fn unreadable(step: []const u8, err: anyerror) LoadError {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    debug_trace.logf("provider_keys", "load failed step={s} err={s}", .{ step, @errorName(err) });
    return error.StoredKeyUnreadable;
}

fn writeFailed(step: []const u8, err: anyerror) StoreError {
    debug_trace.logf("provider_keys", "store failed step={s} err={s}", .{ step, @errorName(err) });
    return error.StoredKeyWriteFailed;
}

test "provider keys round trip, refuse a readable file, and delete" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, dir_name);
    defer dir.close();

    try std.testing.expect(try loadFrom(alloc, dir.dir, "opencode") == null);
    try storeIn(alloc, &dir, "opencode", "sk-first");
    try storeIn(alloc, &dir, "opencode", "sk-second");
    const key = (try loadFrom(alloc, dir.dir, "opencode")).?;
    defer secret.zeroAndFree(alloc, key);
    try std.testing.expectEqualStrings("sk-second", key);

    var file = try dir.dir.openFile(std.testing.io, "opencode", .{ .mode = .read_write });
    try file.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(0o644));
    file.close(std.testing.io);
    try std.testing.expectError(error.StoredKeyInsecure, loadFrom(alloc, dir.dir, "opencode"));

    try std.testing.expectEqual(Deletion.deleted, try deleteIn(dir.dir, "opencode"));
    try std.testing.expectEqual(Deletion.missing, try deleteIn(dir.dir, "opencode"));
}

test "provider keys accept one line of printable ASCII" {
    try validateKey("sk-abc_123.DEF");
    for ([_][]const u8{ "", "sk abc", "sk-abc\n", "sk-\x00", "ключ" }) |key| {
        try std.testing.expectError(error.InvalidProviderKey, validateKey(key));
    }
}
