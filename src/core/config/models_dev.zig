//! Reads model metadata for a configured provider from the models.dev catalog
//! (https://models.dev/api.json), which lists each provider's models with
//! their tool use, image input, reasoning levels, and token limits.
//!
//! This file only parses and merges. Fetching and caching the catalog belong
//! to the native gateway, which owns network and file access.

const std = @import("std");
const configured_provider = @import("configured_provider.zig");
const types = @import("../shared/types.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const Allocator = std.mem.Allocator;
const ModelMetadata = configured_provider.ModelMetadata;

pub const Error = Allocator.Error || error{InvalidModelsDevCatalog};

/// One provider's entry in a models.dev api.json document. Every field is
/// owned; free them with `deinit`.
pub const Provider = struct {
    /// The provider's `models` object, serialized as JSON.
    models_json: []u8,
    /// The display name, or the id when the catalog gives none.
    name: []u8,
    /// The Chat Completions base URL, when the provider has one.
    api: ?[]u8,
    /// The environment variable the provider's key usually lives in.
    env: ?[]u8,

    pub fn deinit(self: *Provider, alloc: Allocator) void {
        alloc.free(self.models_json);
        alloc.free(self.name);
        if (self.api) |value| alloc.free(value);
        if (self.env) |value| alloc.free(value);
        self.* = undefined;
    }
};

/// Returns `provider`'s entry from a models.dev api.json document, or null
/// when the catalog has no such provider. Other providers are skipped without
/// being parsed into values. Caller owns the result.
pub fn extract(alloc: Allocator, api_json: []const u8, provider: []const u8) Error!?Provider {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    var scanner = std.json.Scanner.initCompleteInput(scratch, api_json);
    if ((scanner.next() catch |err| return mapScanError(err)) != .object_begin) return error.InvalidModelsDevCatalog;
    while (true) {
        const key = switch (scanner.nextAlloc(scratch, .alloc_if_needed) catch |err| return mapScanError(err)) {
            .object_end => return null,
            .string, .allocated_string => |name| name,
            else => return error.InvalidModelsDevCatalog,
        };
        if (!std.mem.eql(u8, key, provider)) {
            scanner.skipValue() catch |err| return mapScanError(err);
            continue;
        }

        const value = std.json.innerParse(std.json.Value, scratch, &scanner, .{
            .max_value_len = api_json.len,
            .allocate = .alloc_always,
        }) catch |err| return mapScanError(err);
        if (value != .object) return error.InvalidModelsDevCatalog;
        const models = value.object.get("models") orelse return error.InvalidModelsDevCatalog;
        if (models != .object) return error.InvalidModelsDevCatalog;

        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        std.json.Stringify.value(models, .{}, &out.writer) catch return error.OutOfMemory;

        const name = try alloc.dupe(u8, string(value, "name") orelse provider);
        errdefer alloc.free(name);
        const api = if (string(value, "api")) |text| try alloc.dupe(u8, text) else null;
        errdefer if (api) |text| alloc.free(text);
        const env = if (firstEnv(value)) |text| try alloc.dupe(u8, text) else null;
        errdefer if (env) |text| alloc.free(text);
        return .{ .models_json = try out.toOwnedSlice(), .name = name, .api = api, .env = env };
    }
}

fn string(object: std.json.Value, field: []const u8) ?[]const u8 {
    const value = object.object.get(field) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn firstEnv(object: std.json.Value) ?[]const u8 {
    const value = object.object.get("env") orelse return null;
    if (value != .array or value.array.items.len == 0) return null;
    const first = value.array.items[0];
    return if (first == .string and first.string.len > 0) first.string else null;
}

fn mapScanError(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidModelsDevCatalog;
}

/// Parses a models.dev `models` object into metadata. Deprecated models and
/// entries fx cannot represent are left out rather than failing the whole
/// catalog. A model's `provider.npm` names the SDK models.dev prefers, not the
/// only API that serves it, so it does not filter: OpenCode, for one, serves
/// models it lists under `@ai-sdk/anthropic` through Chat Completions too.
/// Caller owns the result; free it with `configured_provider.freeModelMetadata`.
pub fn parse(alloc: Allocator, models_json: []const u8) Error![]const ModelMetadata {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, models_json, .{}) catch |err| return mapScanError(err);
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidModelsDevCatalog;

    var models: std.ArrayList(ModelMetadata) = .empty;
    errdefer {
        for (models.items) |metadata| {
            alloc.free(metadata.id);
            alloc.free(metadata.reasoning_efforts);
        }
        models.deinit(alloc);
    }

    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (models.items.len == max_models) break;
        const model = entry.value_ptr.*;
        if (model != .object or !usable(entry.key_ptr.*, model)) continue;
        try models.ensureUnusedCapacity(alloc, 1);
        const efforts = try reasoningEfforts(alloc, model);
        errdefer alloc.free(efforts);
        const context = limit(model, "context");
        var output = limit(model, "output");
        // fx needs room for input, so an output limit that fills the whole
        // window is unknown rather than wrong.
        if (context != null and output != null and output.? >= context.?) output = null;
        models.appendAssumeCapacity(.{
            .id = try alloc.dupe(u8, entry.key_ptr.*),
            .context_window = context,
            .max_output_tokens = output,
            .supports_tool_use = flag(model, "tool_call"),
            .supports_vision = acceptsImages(model),
            .supports_reasoning = flag(model, "reasoning"),
            .reasoning_efforts = efforts,
        });
    }
    // models.dev does not keep its order between downloads, so the model
    // menu would reshuffle after every refresh.
    sort_utils.sort(ModelMetadata, models.items, {}, idBefore);
    return models.toOwnedSlice(alloc);
}

fn idBefore(_: void, left: ModelMetadata, right: ModelMetadata) bool {
    return std.mem.lessThan(u8, left.id, right.id);
}

/// The same cap configured metadata has, so a merged catalog stays bounded.
const max_models = 256;

fn usable(id: []const u8, model: std.json.Value) bool {
    configured_provider.validate_model_id(id) catch return false;
    if (model.object.get("status")) |status| {
        if (status == .string and std.mem.eql(u8, status.string, "deprecated")) return false;
    }
    return true;
}

fn flag(model: std.json.Value, name: []const u8) ?bool {
    const value = model.object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn limit(model: std.json.Value, name: []const u8) ?u32 {
    const limits = model.object.get("limit") orelse return null;
    if (limits != .object) return null;
    const value = limits.object.get(name) orelse return null;
    if (value != .integer or value.integer <= 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn acceptsImages(model: std.json.Value) ?bool {
    const modalities = model.object.get("modalities") orelse return null;
    if (modalities != .object) return null;
    const input = modalities.object.get("input") orelse return null;
    if (input != .array) return null;
    for (input.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, "image")) return true;
    }
    return false;
}

/// The levels of the model's `effort` reasoning option, in catalog order.
/// Levels fx cannot name, default labels, and repeats are dropped.
fn reasoningEfforts(alloc: Allocator, model: std.json.Value) Allocator.Error![]const types.ReasoningEffort {
    const options = model.object.get("reasoning_options") orelse return &.{};
    if (options != .array) return &.{};
    for (options.array.items) |option| {
        if (option != .object) continue;
        const kind = option.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "effort")) continue;
        const values = option.object.get("values") orelse continue;
        if (values != .array) continue;

        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        for (values.array.items) |item| {
            if (efforts.items.len == types.ReasoningEffort.max_options) break;
            if (item != .string) continue;
            const effort = types.ReasoningEffort.parse(item.string) orelse continue;
            if (effort.isDefault()) continue;
            for (efforts.items) |existing| {
                if (existing.eql(effort)) break;
            } else try efforts.append(alloc, effort);
        }
        return efforts.toOwnedSlice(alloc);
    }
    return &.{};
}

/// Combines catalog metadata with the provider's declared model_metadata. A
/// declared field overrides the catalog's, a declared limit replaces both of
/// the catalog's limits, and a declared model the catalog lacks is added after
/// the catalog's models. Caller owns the result; free it
/// with `configured_provider.freeModelMetadata`.
pub fn merge(alloc: Allocator, catalog: []const ModelMetadata, declared: []const ModelMetadata) Allocator.Error![]const ModelMetadata {
    var models: std.ArrayList(ModelMetadata) = .empty;
    errdefer {
        for (models.items) |metadata| {
            alloc.free(metadata.id);
            alloc.free(metadata.reasoning_efforts);
        }
        models.deinit(alloc);
    }

    for (catalog) |listed| {
        var combined = listed;
        for (declared) |own| {
            if (!std.mem.eql(u8, own.id, listed.id)) continue;
            combined = overlay(listed, own);
            break;
        }
        try models.ensureUnusedCapacity(alloc, 1);
        models.appendAssumeCapacity(try dupe(alloc, combined));
    }
    for (declared) |own| {
        for (catalog) |listed| {
            if (std.mem.eql(u8, own.id, listed.id)) break;
        } else {
            try models.ensureUnusedCapacity(alloc, 1);
            models.appendAssumeCapacity(try dupe(alloc, own));
        }
    }
    return models.toOwnedSlice(alloc);
}

fn overlay(base: ModelMetadata, own: ModelMetadata) ModelMetadata {
    var combined = base;
    // The two limits only make sense together: a declared window paired with
    // the catalog's output limit can leave no room for input.
    if (own.context_window != null or own.max_output_tokens != null) {
        combined.context_window = own.context_window;
        combined.max_output_tokens = own.max_output_tokens;
    }
    if (own.supports_tool_use) |value| combined.supports_tool_use = value;
    if (own.supports_vision) |value| combined.supports_vision = value;
    if (own.supports_reasoning) |value| combined.supports_reasoning = value;
    if (own.reasoning_efforts.len != 0) combined.reasoning_efforts = own.reasoning_efforts;
    return combined;
}

fn dupe(alloc: Allocator, metadata: ModelMetadata) Allocator.Error!ModelMetadata {
    var owned = metadata;
    owned.id = try alloc.dupe(u8, metadata.id);
    errdefer alloc.free(owned.id);
    owned.reasoning_efforts = try alloc.dupe(types.ReasoningEffort, metadata.reasoning_efforts);
    return owned;
}

const test_catalog =
    \\{"other":{"id":"other","models":{"skipped":{"id":"skipped"}}},
    \\"opencode-go":{"id":"opencode-go","name":"OpenCode Go","env":["OPENCODE_API_KEY"],"api":"https://opencode.ai/inference/go/openai/v1","models":{
    \\"deepseek-v4.1-flash":{"id":"deepseek-v4.1-flash","tool_call":true,"reasoning":true,
    \\  "reasoning_options":[{"type":"effort","values":["low","high","max","high","auto"]}],
    \\  "modalities":{"input":["text","image"],"output":["text"]},"limit":{"context":1000000,"output":384000}},
    \\"glm-text":{"id":"glm-text","tool_call":true,"reasoning":false,"modalities":{"input":["text"]},"limit":{"context":1000,"output":1000}},
    \\"claude-haiku-5-5":{"id":"claude-haiku-5-5","tool_call":true,"provider":{"npm":"@ai-sdk/anthropic","api":"https://opencode.ai/inference/go/anthropic/v1"}},
    \\"compatible":{"id":"compatible","provider":{"npm":"@ai-sdk/openai-compatible"}},
    \\"old":{"id":"old","status":"deprecated"},
    \\"bare":{}}}}
;

test "models.dev extracts one provider and leaves out deprecated models" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try extract(alloc, test_catalog, "missing") == null);
    var provider = (try extract(alloc, test_catalog, "opencode-go")).?;
    defer provider.deinit(alloc);
    try std.testing.expectEqualStrings("OpenCode Go", provider.name);
    try std.testing.expectEqualStrings("https://opencode.ai/inference/go/openai/v1", provider.api.?);
    try std.testing.expectEqualStrings("OPENCODE_API_KEY", provider.env.?);
    var other = (try extract(alloc, test_catalog, "other")).?;
    defer other.deinit(alloc);
    try std.testing.expectEqualStrings("other", other.name);
    try std.testing.expect(other.api == null and other.env == null);
    const models = try parse(alloc, provider.models_json);
    defer configured_provider.freeModelMetadata(alloc, models);

    try std.testing.expectEqual(@as(usize, 5), models.len);
    try std.testing.expectEqualStrings("claude-haiku-5-5", models[1].id);
    const flash = models[3];
    try std.testing.expectEqualStrings("deepseek-v4.1-flash", flash.id);
    try std.testing.expectEqual(@as(?u32, 1_000_000), flash.context_window);
    try std.testing.expectEqual(@as(?u32, 384_000), flash.max_output_tokens);
    try std.testing.expectEqual(@as(?bool, true), flash.supports_tool_use);
    try std.testing.expectEqual(@as(?bool, true), flash.supports_vision);
    try std.testing.expectEqual(@as(?bool, true), flash.supports_reasoning);
    try std.testing.expectEqual(@as(usize, 3), flash.reasoning_efforts.len);
    try std.testing.expectEqualStrings("low", flash.reasoning_efforts[0].label());
    try std.testing.expectEqualStrings("max", flash.reasoning_efforts[2].label());

    const text = models[4];
    try std.testing.expectEqualStrings("glm-text", text.id);
    try std.testing.expectEqual(@as(?bool, false), text.supports_vision);
    try std.testing.expect(text.max_output_tokens == null);
    try std.testing.expectEqual(@as(usize, 0), text.reasoning_efforts.len);

    try std.testing.expectEqualStrings("compatible", models[2].id);
    const bare = models[0];
    try std.testing.expectEqualStrings("bare", bare.id);
    try std.testing.expect(bare.supports_tool_use == null and bare.supports_vision == null and bare.context_window == null);
}

test "models.dev rejects a document that is not a catalog" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidModelsDevCatalog, extract(alloc, "[]", "x"));
    try std.testing.expectError(error.InvalidModelsDevCatalog, extract(alloc, "{\"x\":", "x"));
    try std.testing.expectError(error.InvalidModelsDevCatalog, extract(alloc, "{\"x\":{\"models\":[]}}", "x"));
    try std.testing.expectError(error.InvalidModelsDevCatalog, parse(alloc, "[]"));
}

test "models.dev merge lets declared metadata override and add models" {
    const alloc = std.testing.allocator;
    var declared_registry = try configured_provider.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"https://example.com/v1","auth":{"type":"none"},"model_metadata":{
        \\"deepseek-v4.1-flash":{"context_window":400000,"reasoning_efforts":["high"]},
        \\"private":{"supports_tool_use":true}}}}
    );
    defer declared_registry.deinit(alloc);
    var provider = (try extract(alloc, test_catalog, "opencode-go")).?;
    defer provider.deinit(alloc);
    const catalog = try parse(alloc, provider.models_json);
    defer configured_provider.freeModelMetadata(alloc, catalog);

    const merged = try merge(alloc, catalog, declared_registry.get("local").?.model_metadata);
    defer configured_provider.freeModelMetadata(alloc, merged);
    try std.testing.expectEqual(@as(usize, 6), merged.len);
    const flash = merged[3];
    try std.testing.expectEqual(@as(?u32, 400_000), flash.context_window);
    try std.testing.expect(flash.max_output_tokens == null);
    // A model without declared limits keeps the catalog's.
    try std.testing.expectEqual(@as(?u32, 1000), merged[4].context_window);
    try std.testing.expectEqual(@as(?bool, true), flash.supports_vision);
    try std.testing.expectEqual(@as(usize, 1), flash.reasoning_efforts.len);
    try std.testing.expectEqualStrings("high", flash.reasoning_efforts[0].label());
    try std.testing.expectEqualStrings("private", merged[5].id);
    try std.testing.expectEqual(@as(?bool, true), merged[5].supports_tool_use);
}

test "models.dev parse and merge release memory on allocation failure" {
    const Check = struct {
        fn run(alloc: Allocator) !void {
            var provider = (try extract(alloc, test_catalog, "opencode-go")).?;
            defer provider.deinit(alloc);
            const catalog = try parse(alloc, provider.models_json);
            defer configured_provider.freeModelMetadata(alloc, catalog);
            const merged = try merge(alloc, catalog, catalog[3..4]);
            configured_provider.freeModelMetadata(alloc, merged);
        }
    };
    try std.testing.checkAllAllocationFailures(@import("../shared/testing_allocator.zig").no_resize, Check.run, .{});
}
