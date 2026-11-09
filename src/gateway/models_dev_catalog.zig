//! Lists a configured provider's models from the models.dev catalog when the
//! provider names one with `models_dev`, merged with its declared
//! model_metadata. The provider's own route never comes from the catalog: the
//! catalog only describes models, so a changed catalog cannot send requests or
//! credentials anywhere else.
//!
//! The provider's part of the catalog is cached under
//! `~/.fx/model-catalogs/<id>.json` for a day. A failed refresh keeps using an
//! older copy, and with none the provider lists only its declared models.

const std = @import("std");
const http_tls = @import("../core/shared/http_tls.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const definitions = @import("../core/config/configured_provider.zig");
const models_dev = @import("../core/config/models_dev.zig");
const host_target = @import("../core/hosts/target.zig");
const io_mod = @import("../core/shared/io.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_client = @import("client.zig");
const chat_completions = @import("chat_completions.zig");
const Allocator = std.mem.Allocator;

const default_url = "https://models.dev/api.json";
const test_url_env = "FX_TEST_MODELS_DEV_URL";
const cache_dir_name = "model-catalogs";
const refresh_interval_ms: i64 = 24 * std.time.ms_per_hour;
const fetch_timeout_ms: i64 = 30_000;
/// The whole catalog is about 6 MiB; this leaves room to grow.
const max_api_bytes = 32 * 1024 * 1024;
const max_cache_bytes = 4 * 1024 * 1024;

/// The configured provider's catalog with models.dev lookups. Borrows the
/// definition, which must outlive the provider.
pub fn provider(definition: *const definitions.Definition) catalog.Provider {
    var listed = chat_completions.model_catalog_provider(definition);
    listed.fetch_fn = fetch;
    return listed;
}

fn fetch(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition: *const definitions.Definition = @ptrCast(@alignCast(raw.?));
    const id = definition.models_dev orelse return chat_completions.catalog_from_metadata(alloc, definition.model_metadata);

    const listed = load(alloc, id, input.cancel_flag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("gateway", "models_dev catalog unavailable provider={s} error={s}", .{ id, @errorName(err) });
        return chat_completions.catalog_from_metadata(alloc, definition.model_metadata);
    };
    defer definitions.freeModelMetadata(alloc, listed);

    const merged = try models_dev.merge(alloc, listed, definition.model_metadata);
    defer definitions.freeModelMetadata(alloc, merged);
    return chat_completions.catalog_from_metadata(alloc, merged);
}

/// The provider's models from a fresh cache, else from models.dev, else from
/// an older cache. Caller owns the result.
fn load(alloc: Allocator, id: []const u8, cancel_flag: ?*std.atomic.Value(bool)) ![]const definitions.ModelMetadata {
    if (comptime host_target.is_wasm) return error.ModelsDevUnavailable;

    const cached = readCache(alloc, id) catch |err| blk: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("gateway", "models_dev cache unreadable provider={s} error={s}", .{ id, @errorName(err) });
        break :blk null;
    };
    defer if (cached) |entry| alloc.free(entry.models_json);

    if (cached) |entry| {
        const age = io_mod.milliTimestamp() - entry.saved_ms;
        if (age >= 0 and age < refresh_interval_ms) return models_dev.parse(alloc, entry.models_json);
    }

    const downloaded = download(alloc, id, cancel_flag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const entry = cached orelse return err;
        debug_trace.logf("gateway", "models_dev refresh failed provider={s} error={s}; using cached copy", .{ id, @errorName(err) });
        return models_dev.parse(alloc, entry.models_json);
    };
    defer alloc.free(downloaded);

    writeCache(alloc, id, downloaded) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("gateway", "models_dev cache not saved provider={s} error={s}", .{ id, @errorName(err) });
    };
    return models_dev.parse(alloc, downloaded);
}

/// The provider's `models` object from a fresh download. Caller owns it.
fn download(alloc: Allocator, id: []const u8, cancel_flag: ?*std.atomic.Value(bool)) ![]u8 {
    const entry = try downloadProvider(alloc, id, cancel_flag);
    alloc.free(entry.name);
    if (entry.api) |api| alloc.free(api);
    if (entry.env) |env| alloc.free(env);
    return entry.models_json;
}

/// Downloads models.dev and returns provider `id`'s entry, saving its models
/// to the cache as a refresh would. `fx login` reads the provider's name,
/// base URL, and key variable from it. Caller owns the result.
pub fn lookup(alloc: Allocator, id: []const u8) !models_dev.Provider {
    if (comptime host_target.is_wasm) return error.ModelsDevUnavailable;
    const entry = try downloadProvider(alloc, id, null);
    writeCache(alloc, id, entry.models_json) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("gateway", "models_dev cache not saved provider={s} error={s}", .{ id, @errorName(err) });
    };
    return entry;
}

fn downloadProvider(alloc: Allocator, id: []const u8, cancel_flag: ?*std.atomic.Value(bool)) !models_dev.Provider {
    const url = io_mod.getenv(test_url_env) orelse default_url;
    if (io_mod.getenv(test_url_env) != null and !gateway_client.isLoopbackHttpUrl(url)) return error.InvalidModelsDevTestUrl;

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var operation = Download{ .alloc = alloc, .url = url };
    var body = try gateway_client.runBoundedHttpOperation(Body, alloc, cancel_flag orelse &fallback_cancel, deadline, &operation);
    defer body.deinit(alloc);

    var entry = try models_dev.extract(alloc, body.bytes, id) orelse return error.UnknownModelsDevProvider;
    errdefer entry.deinit(alloc);
    if (entry.models_json.len > max_cache_bytes) return error.ModelsDevCatalogTooLarge;
    return entry;
}

const Body = struct {
    bytes: []u8,

    pub fn deinit(self: *Body, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

const Download = struct {
    alloc: Allocator,
    url: []const u8,

    pub fn run(self: *@This()) !Body {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        // Pages of the buffer that the response never reaches stay untouched.
        const buffer = try self.alloc.alloc(u8, max_api_bytes + 1);
        defer self.alloc.free(buffer);
        var body = std.Io.Writer.fixed(buffer);
        const result = http_tls.fetch(&client, .{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{ .user_agent = .{ .override = gateway_client.user_agent } },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            .response_writer = &body,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ModelsDevCatalogTooLarge,
            else => return err,
        };
        if (result.status != .ok) return error.ModelsDevUnavailable;
        const received = body.buffered();
        if (received.len > max_api_bytes) return error.ModelsDevCatalogTooLarge;
        return .{ .bytes = try self.alloc.dupe(u8, received) };
    }
};

const Cached = struct {
    models_json: []u8,
    saved_ms: i64,
};

fn cacheFile(buffer: []u8, id: []const u8) ![]const u8 {
    return std.mem.print(buffer, "{s}.json", .{id});
}

fn readCache(alloc: Allocator, id: []const u8) !?Cached {
    const home = io_mod.homeDir() orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer home_dir.close(io_mod.getIo());
    var profile_dir = home_dir.openDir(io_mod.getIo(), profile_paths.rootName(), .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer profile_dir.close(io_mod.getIo());
    var cache_dir = profile_dir.openDir(io_mod.getIo(), cache_dir_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer cache_dir.close(io_mod.getIo());
    return readCached(alloc, cache_dir, id);
}

fn readCached(alloc: Allocator, dir: std.Io.Dir, id: []const u8) !?Cached {
    var name_buffer: [definitions.max_id_bytes + 8]u8 = undefined;
    const name = try cacheFile(&name_buffer, id);
    var file = io_mod.openExistingRegularFile(dir, name, .read_only) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.InvalidModelsDevCache;
    return .{
        .models_json = try io_mod.readFileToEnd(alloc, &file, max_cache_bytes),
        .saved_ms = stat.mtime.toMilliseconds(),
    };
}

fn writeCache(alloc: Allocator, id: []const u8, models_json: []const u8) !void {
    const home = io_mod.homeDir() orelse return;
    var home_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true });
    defer home_dir.close(io_mod.getIo());
    var profile_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, profile_paths.rootName());
    defer profile_dir.close();
    var cache_dir = try io_mod.openOrCreateVerifiedPrivateDir(&profile_dir, cache_dir_name);
    defer cache_dir.close();
    try writeCached(alloc, &cache_dir, id, models_json);
}

fn writeCached(alloc: Allocator, dir: *io_mod.VerifiedDir, id: []const u8, models_json: []const u8) !void {
    var name_buffer: [definitions.max_id_bytes + 8]u8 = undefined;
    try io_mod.durableReplaceVerified(alloc, dir, try cacheFile(&name_buffer, id), models_json);
}

test "models.dev cache round trips a provider's models" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, cache_dir_name);
    defer dir.close();

    try std.testing.expect(try readCached(alloc, dir.dir, "opencode-go") == null);
    try writeCached(alloc, &dir, "opencode-go", "{\"m\":{\"tool_call\":true}}");
    const cached = (try readCached(alloc, dir.dir, "opencode-go")).?;
    defer alloc.free(cached.models_json);
    try std.testing.expectEqualStrings("{\"m\":{\"tool_call\":true}}", cached.models_json);
    try std.testing.expect(cached.saved_ms > 0);
}

test "models.dev provider lists declared models without a catalog id" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"supports_vision":true}}}}
    );
    defer registry.deinit(alloc);
    const listed = provider(registry.get("local").?);
    var fetched = try listed.fetch(alloc, .{ .endpoint = "unused" });
    defer catalog.freeModelCatalog(alloc, &fetched.catalog);
    try std.testing.expectEqual(@as(usize, 1), fetched.catalog.items.len);
    try std.testing.expect(fetched.catalog.items[0].has_vision);
}
