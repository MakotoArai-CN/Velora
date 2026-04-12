const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const output = @import("output.zig");
const terminal = @import("terminal.zig");
const i18n = @import("i18n.zig");
const config_mod = @import("config.zig");
const sites_mod = @import("sites.zig");
const apply_mod = @import("apply.zig");
const check_mod = @import("check.zig");
const install_mod = @import("install.zig");
const update_mod = @import("update.zig");
const app = @import("app.zig");

const build_options = @import("build_options");
pub const version = build_options.version;

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ gpa_impl.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = gpa_impl.deinit();
    };

    const config = cli.parseArgs(gpa) catch |err| {
        switch (err) {
            error.HelpRequested, error.VersionRequested => return,
            error.InvalidArgument => {
                var stderr_buffer: [512]u8 = undefined;
                var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
                const w = &stderr_writer.interface;
                w.print("Invalid argument. Use 'velora --help' for usage.\n", .{}) catch {};
                w.flush() catch {};
                return;
            },
            error.OutOfMemory => {
                var stderr_buffer: [512]u8 = undefined;
                var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
                const w = &stderr_writer.interface;
                w.print("Out of memory.\n", .{}) catch {};
                w.flush() catch {};
                return;
            },
        }
    };

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const w: *std.Io.Writer = &stdout_writer.interface;
    const caps = terminal.TermCaps.detect();
    const lang = config.language;

    try output.printBanner(w, caps, version);
    try w.flush();

    switch (config.command) {
        .add => |args| try runAdd(gpa, w, caps, lang, args),
        .edit => |args| try runEdit(gpa, w, caps, lang, args),
        .del => |args| try runDel(gpa, w, caps, lang, args),
        .list => |args| try runList(gpa, w, caps, lang, args),
        .use => |args| try runUse(gpa, w, caps, lang, args),
        .set => |args| try runSet(gpa, w, caps, lang, args),
        .models => |args| try runModels(gpa, w, caps, lang, args),
        .install => try runInstall(gpa, w, caps, lang),
        .uninstall => try runUninstall(gpa, w, caps, lang),
        .update_check => try runUpdate(gpa, w, caps, lang),
        .version => try runVersion(gpa, w, caps, lang),
        .help => {},
    }
}

// --- Add ---

fn runAdd(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, args: cli.AddArgs) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Add Site", "添加站点", "サイト追加"), caps);

    var store = try sites_mod.loadSites(allocator);
    defer store.deinit(allocator);

    const existing = store.getSite(args.alias);

    // Direct mode: all fields provided via CLI
    if (args.site_type != null and args.base_url != null and args.api_key != null) {
        const normalized_base_url = try check_mod.normalizedAddBaseUrl(allocator, args.base_url.?);
        defer allocator.free(normalized_base_url);
        const site = sites_mod.Site{
            .site_type = args.site_type.?,
            .base_url = normalized_base_url,
            .api_key = args.api_key.?,
            .model = args.model orelse sites_mod.defaultModelForType(args.site_type.?),
            .default_tools_mask = sites_mod.toolMask(args.site_type.?),
        };
        try store.addOrUpdate(allocator, args.alias, site);
        try sites_mod.saveSites(allocator, &store);

        if (check_mod.normalizeBaseUrlDisplayChanged(args.base_url.?, normalized_base_url)) {
            var norm_buf: [512]u8 = undefined;
            const norm_msg = std.fmt.bufPrint(&norm_buf, "{s}: {s}", .{
                i18n.tr(lang, "Normalized Base URL", "已规范化 Base URL", "Base URL を正規化しました"),
                normalized_base_url,
            }) catch normalized_base_url;
            try output.printInfo(w, norm_msg, caps);
        }

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Site '{s}' added ({s})", .{ args.alias, site.site_type.displayName() }) catch "Site added";
        try output.printSuccess(w, msg, caps);
        try w.flush();
        return;
    }

    if (existing == null and args.site_type == null) {
        const raw_base_url = askBaseUrl(w, caps, lang, null);
        const api_key = askApiKey(w, caps, lang, null);
        var probe = try check_mod.probeAddEndpoint(allocator, raw_base_url, api_key);
        defer check_mod.freeAddProbeResult(allocator, &probe);

        if (check_mod.normalizeBaseUrlDisplayChanged(raw_base_url, probe.normalized_base_url)) {
            var norm_buf: [512]u8 = undefined;
            const norm_msg = std.fmt.bufPrint(&norm_buf, "{s}: {s}", .{
                i18n.tr(lang, "Normalized Base URL", "已规范化 Base URL", "Base URL を正規化しました"),
                probe.normalized_base_url,
            }) catch probe.normalized_base_url;
            try output.printInfo(w, norm_msg, caps);
        }

        try printProbeSummary(w, caps, lang, probe);
        var selected_buf: [5]sites_mod.SiteType = undefined;
        const selected_tools = askDefaultTools(w, caps, lang, probe, &selected_buf);

        var site = sites_mod.Site{
            .site_type = check_mod.probeSuggestedSiteType(probe),
            .base_url = probe.normalized_base_url,
            .api_key = api_key,
        };
        applyProbeDefaults(&site, probe, selected_tools);
        try store.addOrUpdate(allocator, args.alias, site);
        try sites_mod.saveSites(allocator, &store);

        var tools_buf: [128]u8 = undefined;
        const tools_text = sites_mod.defaultToolsSummary(site, &tools_buf);
        var msg_buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Site '{s}' added ({s}) [{s}]", .{ args.alias, site.site_type.displayName(), tools_text }) catch "Site added";
        try output.printSuccess(w, msg, caps);
        try w.flush();
        return;
    }


    // Interactive mode
    if (existing) |ex| {
        // Copy existing values to local buffers to avoid use-after-free
        var saved_url_buf: [512]u8 = undefined;
        var saved_key_buf: [512]u8 = undefined;
        var saved_model_buf: [256]u8 = undefined;
        const saved_url = bufCopy(&saved_url_buf, ex.base_url);
        const saved_key = bufCopy(&saved_key_buf, ex.api_key);
        const saved_model = bufCopy(&saved_model_buf, ex.model);
        const saved_type = ex.site_type;

        // Site already exists
        var alias_buf: [128]u8 = undefined;
        const prompt_msg = std.fmt.bufPrint(&alias_buf, "{s} '{s}' {s}", .{
            i18n.tr(lang, "Site", "站点", "サイト"),
            args.alias,
            i18n.tr(lang, "already exists. Continue configuring? [Y/n]", "已存在，继续配置？[Y/n]", "は既に存在します。設定を続けますか？[Y/n]"),
        }) catch "Site exists. Continue? [Y/n]";
        try output.printWarning(w, prompt_msg, caps);
        try w.flush();

        const answer = readLine();
        const continue_edit = answer.len == 0 or answer[0] == 'y' or answer[0] == 'Y';

        if (continue_edit) {
            // Fill in missing fields
            const site_type = args.site_type orelse askSiteType(w, caps, lang) orelse saved_type;
            const base_url = askBaseUrl(w, caps, lang, saved_url);
            const api_key = askApiKey(w, caps, lang, saved_key);
            const model = askModel(w, caps, lang, site_type, if (saved_model.len > 0) saved_model else null);

            const site = sites_mod.Site{ .site_type = site_type, .base_url = base_url, .api_key = api_key, .model = model };
            try store.addOrUpdate(allocator, args.alias, site);
            try sites_mod.saveSites(allocator, &store);
            try output.printSuccess(w, i18n.tr(lang, "Site updated", "站点已更新", "サイトを更新しました"), caps);
        } else {
            // Full reconfigure
            const site_type = args.site_type orelse askSiteType(w, caps, lang) orelse return;
            const base_url = askBaseUrl(w, caps, lang, null);
            const api_key = askApiKey(w, caps, lang, null);
            const model = askModel(w, caps, lang, site_type, null);

            const site = sites_mod.Site{ .site_type = site_type, .base_url = base_url, .api_key = api_key, .model = model };
            try store.addOrUpdate(allocator, args.alias, site);
            try sites_mod.saveSites(allocator, &store);
            try output.printSuccess(w, i18n.tr(lang, "Site reconfigured", "站点已重新配置", "サイトを再設定しました"), caps);
        }
    } else {
        // New site
        if (args.site_type) |explicit_type| {
            const raw_base_url = askBaseUrl(w, caps, lang, null);
            const normalized_base_url = try check_mod.normalizedAddBaseUrl(allocator, raw_base_url);
            defer allocator.free(normalized_base_url);
            if (check_mod.normalizeBaseUrlDisplayChanged(raw_base_url, normalized_base_url)) {
                var norm_buf: [512]u8 = undefined;
                const norm_msg = std.fmt.bufPrint(&norm_buf, "{s}: {s}", .{
                    i18n.tr(lang, "Normalized Base URL", "已规范化 Base URL", "Base URL を正規化しました"),
                    normalized_base_url,
                }) catch normalized_base_url;
                try output.printInfo(w, norm_msg, caps);
            }
            const api_key = askApiKey(w, caps, lang, null);
            const model = askModel(w, caps, lang, explicit_type, args.model);

            var site = sites_mod.Site{
                .site_type = explicit_type,
                .base_url = normalized_base_url,
                .api_key = api_key,
                .model = model,
            };
            sites_mod.setLegacyDefaults(&site);
            try store.addOrUpdate(allocator, args.alias, site);
            try sites_mod.saveSites(allocator, &store);

            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Site '{s}' added ({s})", .{ args.alias, site.site_type.displayName() }) catch "Site added";
            try output.printSuccess(w, msg, caps);
        } else {
            const raw_base_url = askBaseUrl(w, caps, lang, null);
            const normalized_base_url = try check_mod.normalizedAddBaseUrl(allocator, raw_base_url);
            defer allocator.free(normalized_base_url);
            if (check_mod.normalizeBaseUrlDisplayChanged(raw_base_url, normalized_base_url)) {
                var norm_buf: [512]u8 = undefined;
                const norm_msg = std.fmt.bufPrint(&norm_buf, "{s}: {s}", .{
                    i18n.tr(lang, "Normalized Base URL", "已规范化 Base URL", "Base URL を正規化しました"),
                    normalized_base_url,
                }) catch normalized_base_url;
                try output.printInfo(w, norm_msg, caps);
                try w.flush();
            }
            const api_key = askApiKey(w, caps, lang, null);
            var probe = try check_mod.probeAddEndpoint(allocator, normalized_base_url, api_key);
            defer check_mod.freeAddProbeResult(allocator, &probe);
            try printProbeSummary(w, caps, lang, probe);

            var selected_buf: [5]sites_mod.SiteType = undefined;
            const selected_tools = askDefaultTools(w, caps, lang, probe, &selected_buf);

            var site = sites_mod.Site{
                .site_type = check_mod.probeSuggestedSiteType(probe),
                .base_url = probe.normalized_base_url,
                .api_key = api_key,
            };
            applyProbeDefaults(&site, probe, selected_tools);
            try store.addOrUpdate(allocator, args.alias, site);
            try sites_mod.saveSites(allocator, &store);

            var tools_buf: [128]u8 = undefined;
            const tools_text = sites_mod.defaultToolsSummary(site, &tools_buf);
            var msg_buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Site '{s}' added ({s}) [{s}]", .{ args.alias, site.site_type.displayName(), tools_text }) catch "Site added";
            try output.printSuccess(w, msg, caps);
        }
    }
    try w.flush();
}

// --- Edit ---

fn runEdit(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, args: cli.EditArgs) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Edit Site", "编辑站点", "サイト編集"), caps);

    var store = try sites_mod.loadSites(allocator);
    defer store.deinit(allocator);

    const existing = store.getSite(args.alias) orelse {
        // Fuzzy match suggestion
        if (findClosestAlias(&store, args.alias)) |suggestion| {
            var suggest_buf: [256]u8 = undefined;
            const suggest_msg = std.fmt.bufPrint(&suggest_buf, "{s} '{s}' {s}. {s} '{s}'? [Y/n]", .{
                i18n.tr(lang, "Site", "站点", "サイト"),
                args.alias,
                i18n.tr(lang, "not found", "未找到", "が見つかりません"),
                i18n.tr(lang, "Did you mean", "你是否想输入", "もしかして"),
                suggestion,
            }) catch "Site not found";
            try output.printWarning(w, suggest_msg, caps);
            try w.flush();
            const answer = readLine();
            if (answer.len == 0 or answer[0] == 'y' or answer[0] == 'Y') {
                const corrected_args = cli.EditArgs{ .alias = suggestion };
                return runEdit(allocator, w, caps, lang, corrected_args);
            }
        } else {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Site '{s}' not found", .{args.alias}) catch "Site not found";
            try output.printError(w, err_msg, caps);
        }
        try w.flush();
        return;
    };

    // Copy existing values to local buffers to avoid use-after-free when addOrUpdate frees old strings
    var saved_url_buf: [512]u8 = undefined;
    var saved_key_buf: [512]u8 = undefined;
    var saved_model_buf: [256]u8 = undefined;
    const saved_url = bufCopy(&saved_url_buf, existing.base_url);
    const saved_key = bufCopy(&saved_key_buf, existing.api_key);
    const saved_model = bufCopy(&saved_model_buf, existing.model);
    const saved_type = existing.site_type;

    // Show current config
    try output.printInfo(w, i18n.tr(lang, "Current configuration:", "当前配置:", "現在の設定:"), caps);
    try output.printKeyValue(w, "  Type:", saved_type.displayName(), caps);
    try output.printKeyValue(w, "  Base URL:", saved_url, caps);
    var masked_buf: [64]u8 = undefined;
    const masked = sites_mod.maskKey(&masked_buf, saved_key);
    try output.printKeyValue(w, "  API Key:", masked, caps);
    const eff_model = if (saved_model.len > 0) saved_model else sites_mod.defaultModelForType(saved_type);
    try output.printKeyValue(w, "  Model:", eff_model, caps);
    try output.printSeparator(w, caps);

    try output.printInfo(w, i18n.tr(lang, "Press Enter to keep current value", "按回车保留当前值", "Enterキーで現在の値を保持"), caps);
    try w.flush();

    const site_type = askSiteType(w, caps, lang) orelse saved_type;
    const base_url = askBaseUrl(w, caps, lang, saved_url);
    const api_key = askApiKey(w, caps, lang, saved_key);
    const model = askModel(w, caps, lang, site_type, if (saved_model.len > 0) saved_model else null);

    const site = sites_mod.Site{ .site_type = site_type, .base_url = base_url, .api_key = api_key, .model = model };
    try store.addOrUpdate(allocator, args.alias, site);
    try sites_mod.saveSites(allocator, &store);

    try output.printSuccess(w, i18n.tr(lang, "Site updated", "站点已更新", "サイトを更新しました"), caps);
    try w.flush();
}

// --- Del ---

fn runDel(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, args: cli.DelArgs) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Delete Site", "删除站点", "サイト削除"), caps);

    var store = try sites_mod.loadSites(allocator);
    defer store.deinit(allocator);

    if (store.getSite(args.alias) == null) {
        // Fuzzy match suggestion
        if (findClosestAlias(&store, args.alias)) |suggestion| {
            var suggest_buf: [256]u8 = undefined;
            const suggest_msg = std.fmt.bufPrint(&suggest_buf, "{s} '{s}' {s}. {s} '{s}'? [Y/n]", .{
                i18n.tr(lang, "Site", "站点", "サイト"),
                args.alias,
                i18n.tr(lang, "not found", "未找到", "が見つかりません"),
                i18n.tr(lang, "Did you mean", "你是否想输入", "もしかして"),
                suggestion,
            }) catch "Site not found";
            try output.printWarning(w, suggest_msg, caps);
            try w.flush();
            const answer = readLine();
            if (answer.len == 0 or answer[0] == 'y' or answer[0] == 'Y') {
                const corrected_args = cli.DelArgs{ .alias = suggestion };
                return runDel(allocator, w, caps, lang, corrected_args);
            }
        } else {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Site '{s}' not found", .{args.alias}) catch "Site not found";
            try output.printError(w, err_msg, caps);
        }
        try w.flush();
        return;
    }

    var prompt_buf: [128]u8 = undefined;
    const prompt_msg = std.fmt.bufPrint(&prompt_buf, "{s} '{s}'? [y/N]", .{
        i18n.tr(lang, "Delete site", "删除站点", "サイトを削除"),
        args.alias,
    }) catch "Delete? [y/N]";
    try output.printWarning(w, prompt_msg, caps);
    try w.flush();

    const answer = readLine();
    if (answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y')) {
        _ = store.remove(allocator, args.alias);
        try sites_mod.saveSites(allocator, &store);
        try output.printSuccess(w, i18n.tr(lang, "Site deleted", "站点已删除", "サイトを削除しました"), caps);
    } else {
        try output.printInfo(w, i18n.tr(lang, "Cancelled", "已取消", "キャンセルしました"), caps);
    }
    try w.flush();
}

// --- List ---

fn runList(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, args: cli.ListArgs) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Sites", "站点列表", "サイト一覧"), caps);

    var store = try sites_mod.loadSites(allocator);
    defer store.deinit(allocator);

    if (store.count == 0) {
        try output.printInfo(w, i18n.tr(lang, "No sites configured. Use 'velora add<alias>' to add one.", "未配置站点，使用 'velora add<别名>' 添加", "サイトが未設定です。'velora add<エイリアス>' で追加してください"), caps);
        try w.flush();
        return;
    }

    const settings = sites_mod.loadSettings(allocator);

    if (args.show_all) {
        // Detailed view - single column, show base_url + masked api_key + archived status
        for (0..store.count) |i| {
            const entry = store.entries[i];
            try w.print("\n", .{});

            var alias_buf: [128]u8 = undefined;
            const alias_display = if (entry.site.archived)
                std.fmt.bufPrint(&alias_buf, "{s} ({s}) [{s}]", .{
                    entry.alias,
                    entry.site.site_type.displayName(),
                    i18n.tr(lang, "archived", "已归档", "アーカイブ済"),
                }) catch entry.alias
            else
                std.fmt.bufPrint(&alias_buf, "{s} ({s})", .{ entry.alias, entry.site.site_type.displayName() }) catch entry.alias;
            try output.printInfo(w, alias_display, caps);
            try output.printKeyValue(w, "    Base URL:", entry.site.base_url, caps);
            var masked_buf: [64]u8 = undefined;
            const masked = sites_mod.maskKey(&masked_buf, entry.site.api_key);
            try output.printKeyValue(w, "    API Key:", masked, caps);
            try output.printKeyValue(w, "    Model:", entry.site.effectiveModel(), caps);
        }
        try output.printSeparator(w, caps);
        try w.flush();
        return;
    }

    // Build list of indices to check
    var check_indices: [64]usize = undefined;
    var check_count: usize = 0;

    if (args.global_check) {
        // -g: check ALL sites including archived
        for (0..store.count) |i| {
            check_indices[check_count] = i;
            check_count += 1;
        }
    } else {
        // Normal: only non-archived sites
        for (0..store.count) |i| {
            if (!store.entries[i].site.archived) {
                check_indices[check_count] = i;
                check_count += 1;
            }
        }
    }

    if (check_count == 0) {
        try output.printInfo(w, i18n.tr(lang, "No active sites. Use 'velora list -g' to check archived sites.", "无活跃站点。使用 'velora list -g' 检查已归档站点", "アクティブなサイトがありません。'velora list -g' でアーカイブ済みサイトを確認"), caps);
        try w.flush();
        return;
    }

    if (!settings.list_latency) {
        // No latency check - just show sites statically
        for (0..check_count) |ci| {
            const entry = store.entries[check_indices[ci]];
            var archived_tag_buf: [32]u8 = undefined;
            const archived_tag = if (entry.site.archived)
                std.fmt.bufPrint(&archived_tag_buf, " [{s}]", .{
                    i18n.tr(lang, "archived", "已归档", "アーカイブ済"),
                }) catch " [archived]"
            else
                "";
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "  {s}{s} ({s}){s}{s}", .{
                if (caps.color) output.Color.miku_white else "",
                entry.alias,
                entry.site.site_type.displayName(),
                archived_tag,
                if (caps.color) output.Color.reset else "",
            }) catch "";
            try w.print("{s}\n", .{line});
        }
        try output.printSeparator(w, caps);
        try w.flush();
        return;
    }

    // Phase 1: Print all sites with pending status
    for (0..check_count) |ci| {
        const entry = store.entries[check_indices[ci]];
        try printSitePendingLine(w, caps, entry.alias, entry.site.site_type);
    }
    try w.flush();

    // Phase 2: Test each site and update the line in place
    var store_changed = false;
    for (0..check_count) |ci| {
        const idx = check_indices[ci];
        const entry = store.entries[idx];
        const conn = check_mod.checkConnectivity(allocator, entry.site.base_url);

        const lines_up = check_count - ci;
        var esc_buf: [32]u8 = undefined;
        const esc = std.fmt.bufPrint(&esc_buf, "\x1b[{d}A\r\x1b[2K", .{lines_up}) catch "";
        try w.print("{s}", .{esc});

        const status = check_mod.SiteStatus{
            .alias = entry.alias,
            .site = entry.site,
            .conn = conn,
        };
        try printSiteStatusLine(w, caps, status, 0);

        var down_buf: [32]u8 = undefined;
        const down = std.fmt.bufPrint(&down_buf, "\x1b[{d}B", .{lines_up}) catch "";
        try w.print("{s}", .{down});
        try w.flush();

        // Smart archival logic (only when auto_archive is enabled)
        if (settings.auto_archive) {
            if (!conn.reachable and !entry.site.archived) {
                // Auto-archive unreachable site
                store.entries[idx].site.archived = true;
                store_changed = true;
            } else if (conn.reachable and entry.site.archived) {
                // Auto-unarchive reachable archived site
                store.entries[idx].site.archived = false;
                store_changed = true;
            }
        } else if (args.global_check) {
            // In -g mode without auto_archive, still auto-unarchive reachable archived sites
            if (conn.reachable and entry.site.archived) {
                store.entries[idx].site.archived = false;
                store_changed = true;
            }
        }
    }

    try w.flush();

    if (store_changed) {
        sites_mod.saveSites(allocator, &store) catch {};
    }

    try output.printSeparator(w, caps);
    try w.flush();
}

fn printSitePendingLine(w: *std.Io.Writer, caps: terminal.TermCaps, alias: []const u8, site_type: sites_mod.SiteType) !void {
    const pending_sym = if (caps.unicode) "◌" else "[.]";
    var line_buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "  {s}{s}{s}{s} {s} ({s}) {s}...{s}", .{
        if (caps.color) output.Color.miku_gray else "",
        pending_sym,
        if (caps.color) output.Color.reset else "",
        if (caps.color) output.Color.miku_white else "",
        alias,
        site_type.displayName(),
        if (caps.color) output.Color.miku_gray else "",
        if (caps.color) output.Color.reset else "",
    }) catch "";
    try w.print("{s}\n", .{line});
}

fn printSiteStatusLine(w: *std.Io.Writer, caps: terminal.TermCaps, status: check_mod.SiteStatus, col_width: u32) !void {
    const check_sym = if (caps.unicode) "✓" else "[OK]";
    const fail_sym = if (caps.unicode) "✗" else "[X]";

    if (status.conn.reachable) {
        var latency_buf: [32]u8 = undefined;
        const latency_str = if (status.conn.latency_ms) |ms|
            std.fmt.bufPrint(&latency_buf, "{d}ms", .{ms}) catch "?"
        else
            "?";

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s}{s}{s}{s} {s} ({s}) {s}{s}{s}", .{
            if (caps.color) output.Color.miku_green else "",
            check_sym,
            if (caps.color) output.Color.reset else "",
            if (caps.color) output.Color.miku_white else "",
            status.alias,
            status.site.site_type.displayName(),
            if (caps.color) output.Color.miku_gray else "",
            latency_str,
            if (caps.color) output.Color.reset else "",
        }) catch "";
        try w.print("{s}", .{line});
    } else {
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s}{s}{s}{s} {s} ({s}) {s}unreachable{s}", .{
            if (caps.color) output.Color.miku_red else "",
            fail_sym,
            if (caps.color) output.Color.reset else "",
            if (caps.color) output.Color.miku_white else "",
            status.alias,
            status.site.site_type.displayName(),
            if (caps.color) output.Color.miku_red else "",
            if (caps.color) output.Color.reset else "",
        }) catch "";
        try w.print("{s}", .{line});
    }

    if (col_width > 0) {
        // Pad to column width for two-column layout
        const actual_w = output.displayWidth(status.alias) + 20; // rough estimate
        if (actual_w < col_width) {
            var remaining = col_width - actual_w;
            while (remaining > 0) : (remaining -= 1) {
                try w.print(" ", .{});
            }
        }
    } else {
        try w.print("\n", .{});
    }
}

// --- Use ---

fn runUse(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, args: cli.UseArgs) !void {
    var store = try sites_mod.loadSites(allocator);
    defer store.deinit(allocator);

    const site = store.getSite(args.alias) orelse {
        // Fuzzy match suggestion
        if (findClosestAlias(&store, args.alias)) |suggestion| {
            var suggest_buf: [256]u8 = undefined;
            const suggest_msg = std.fmt.bufPrint(&suggest_buf, "{s} '{s}' {s}. {s} '{s}'? [Y/n]", .{
                i18n.tr(lang, "Site", "站点", "サイト"),
                args.alias,
                i18n.tr(lang, "not found", "未找到", "が見つかりません"),
                i18n.tr(lang, "Did you mean", "你是否想输入", "もしかして"),
                suggestion,
            }) catch "Site not found";
            try output.printWarning(w, suggest_msg, caps);
            try w.flush();
            const answer = readLine();
            if (answer.len == 0 or answer[0] == 'y' or answer[0] == 'Y') {
                const corrected_args = cli.UseArgs{ .site_type = args.site_type, .alias = suggestion, .model = args.model };
                return runUse(allocator, w, caps, lang, corrected_args);
            }
        } else {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Site '{s}' not found", .{args.alias}) catch "Site not found";
            try output.printError(w, err_msg, caps);
        }
        try w.flush();
        return;
    };

    if (args.site_type == null and sites_mod.defaultToolCount(site) > 1) {
        var targets_buf: [5]sites_mod.SiteType = undefined;
        const targets = sites_mod.availableDefaultTools(site, &targets_buf);
        for (targets) |tool| {
            const explicit_args = cli.UseArgs{ .site_type = tool, .alias = args.alias, .model = args.model };
            try runUse(allocator, w, caps, lang, explicit_args);
        }
        return;
    }

    // Determine target type: explicit arg or stored default preference
    const target_type = args.site_type orelse sites_mod.implicitTargetTool(site);

    const header = switch (target_type) {
        .cx => i18n.tr(lang, "Apply to Codex", "应用到 Codex", "Codexに適用"),
        .cc => i18n.tr(lang, "Apply to Claude Code", "应用到 Claude Code", "Claude Codeに適用"),
        .oc => i18n.tr(lang, "Apply to OpenCode", "应用到 OpenCode", "OpenCodeに適用"),
        .nb => i18n.tr(lang, "Apply to Nanobot", "应用到 Nanobot", "Nanobotに適用"),
        .ow => i18n.tr(lang, "Apply to OpenClaw", "应用到 OpenClaw", "OpenClawに適用"),
    };
    try output.printSectionHeader(w, header, caps);

    // CLI tool detection warning
    if (!check_mod.isToolInstalled(target_type)) {
        var tool_warn_buf: [256]u8 = undefined;
        const tool_warn = std.fmt.bufPrint(&tool_warn_buf, "{s} ({s})", .{
            i18n.tr(lang, "Target tool not detected in PATH", "目标工具未在 PATH 中检测到", "対象ツールがPATHに見つかりません"),
            target_type.displayName(),
        }) catch "Tool not found";
        try output.printWarning(w, tool_warn, caps);
        try w.flush();
    }

    // Type mismatch warning (only when type was explicitly specified)
    if (args.site_type != null and site.site_type != target_type) {
        var warn_buf: [256]u8 = undefined;
        const warn_msg = std.fmt.bufPrint(&warn_buf, "{s} (site type: {s}, target: {s})", .{
            i18n.tr(lang, "Type mismatch", "类型不匹配", "タイプ不一致"),
            site.site_type.displayName(),
            target_type.displayName(),
        }) catch "Type mismatch";
        try output.printWarning(w, warn_msg, caps);
        try w.flush();
    }

    // Auto-unarchive if site is archived
    if (site.archived) {
        _ = sites_mod.updateArchived(&store, args.alias, false);
        try sites_mod.saveSites(allocator, &store);
        try output.printInfo(w, i18n.tr(lang, "Site unarchived", "站点已取消归档", "サイトのアーカイブを解除しました"), caps);
        try w.flush();
    }

    const settings = sites_mod.loadSettings(allocator);
    const mismatch = args.site_type != null and site.site_type != target_type;

    var fetched_models: ?[][]const u8 = null;
    defer if (fetched_models) |models| {
        for (models) |item| allocator.free(item);
        allocator.free(models);
    };

    if (mismatch and (settings.auto_pick_compatible_model or args.model != null)) {
        fetched_models = check_mod.fetchModelList(allocator, site.base_url, site.api_key) catch null;
    }

    var tool_model = site.effectiveModelForTool(target_type);
    var persist_override = false;

    if (args.model) |requested_model| {
        const family_ok = check_mod.isModelCompatibleForTool(target_type, requested_model);

        if (family_ok) {
            tool_model = requested_model;
            persist_override = true;
        } else {
            var warn_buf: [256]u8 = undefined;
            const warn_msg = std.fmt.bufPrint(&warn_buf, "{s} '{s}' ({s})", .{
                i18n.tr(lang, "Requested model is not compatible for target tool, keeping current behavior", "指定模型与目标工具不兼容，保持当前行为", "指定モデルは対象ツールと互換性がないため、現在の動作を維持します"),
                requested_model,
                if (!family_ok)
                    i18n.tr(lang, "family mismatch", "模型系列不匹配", "モデル系列が不一致")
                else
                    i18n.tr(lang, "not found in model list", "未在模型列表中找到", "モデル一覧に見つかりません"),
            }) catch "Requested model incompatible";
            try output.printWarning(w, warn_msg, caps);
            try w.flush();
        }
    } else if (mismatch and settings.auto_pick_compatible_model and site.modelOverrideForTool(target_type).len == 0) {
        if (fetched_models) |models| {
            if (check_mod.pickBestCompatibleModel(models, target_type)) |picked| {
                tool_model = picked;
                persist_override = true;
                var info_buf: [256]u8 = undefined;
                const info_msg = std.fmt.bufPrint(&info_buf, "{s}: {s}", .{
                    i18n.tr(lang, "Auto-selected compatible model", "已自动选择兼容模型", "互換モデルを自動選択しました"),
                    picked,
                }) catch "Auto-selected compatible model";
                try output.printInfo(w, info_msg, caps);
                try w.flush();
            } else {
                try output.printWarning(w, i18n.tr(lang, "No compatible model found for target tool, keeping current behavior", "未找到适用于目标工具的兼容模型，保持当前行为", "対象ツール向けの互換モデルが見つからないため、現在の動作を維持します"), caps);
                try w.flush();
            }
        } else {
            try output.printWarning(w, i18n.tr(lang, "Could not fetch model list for compatibility check, keeping current behavior", "无法获取模型列表进行兼容性检查，保持当前行为", "互換性確認用のモデル一覧を取得できないため、現在の動作を維持します"), caps);
            try w.flush();
        }
    }

    if (persist_override) {
        _ = try sites_mod.setToolModelOverride(&store, allocator, args.alias, target_type, tool_model);
        try sites_mod.saveSites(allocator, &store);
    }

    const site_entry = sites_mod.findEntryConst(&store, args.alias) orelse return;
    const apply_site = site_entry.site;

    // Apply
    switch (target_type) {
        .cx => try apply_mod.applyToCodex(allocator, w, caps, lang, apply_site, tool_model),
        .cc => try apply_mod.applyToClaudeCode(allocator, w, caps, lang, apply_site, tool_model),
        .oc => try apply_mod.applyToOpenCode(allocator, w, caps, lang, apply_site, tool_model),
        .nb => try apply_mod.applyToNanobot(allocator, w, caps, lang, apply_site, tool_model),
        .ow => try apply_mod.applyToOpenClaw(allocator, w, caps, lang, apply_site, tool_model),
    }

    if (sites_mod.findEntry(&store, args.alias)) |entry| {
        sites_mod.updateLastUsed(&entry.site, target_type);
        try sites_mod.saveSites(allocator, &store);
    }

    const updated_site = (sites_mod.findEntryConst(&store, args.alias) orelse site_entry).site;

    // Model detection (if enabled)
    if (!settings.model_check) {
        try output.printSeparator(w, caps);
        try w.flush();
        return;
    }

    try output.printInfo(w, i18n.tr(lang, "Detecting models...", "正在检测模型...", "モデルを検出中..."), caps);
    try w.flush();

    const model_info = check_mod.detectModels(allocator, updated_site.base_url, updated_site.api_key, target_type);

    if (model_info.models_found > 0) {
        var model_buf: [128]u8 = undefined;
        const model_msg = std.fmt.bufPrint(&model_buf, "{d} models found", .{model_info.models_found}) catch "Models found";
        if (model_info.has_expected) {
            try output.printSuccess(w, model_msg, caps);
        } else {
            try output.printWarning(w, model_msg, caps);
            try output.printWarning(w, i18n.tr(lang, "Expected models not found", "未找到预期的模型", "期待するモデルが見つかりません"), caps);
        }

        if (model_info.provider_type != .unknown) {
            var type_buf: [128]u8 = undefined;
            const type_msg = std.fmt.bufPrint(&type_buf, "{s}: {s}", .{
                i18n.tr(lang, "Provider type", "\xe7\xab\x99\xe7\x82\xb9\xe7\xb1\xbb\xe5\x9e\x8b", "\xe3\x82\xb5\xe3\x82\xa4\xe3\x83\x88\xe7\xa8\xae\xe5\x88\xa5"),
                model_info.provider_type.displayName(lang),
            }) catch "Provider type detected";
            switch (model_info.provider_type) {
                .official => try output.printSuccess(w, type_msg, caps),
                .relay => try output.printInfo(w, type_msg, caps),
                .reverse_proxy => try output.printWarning(w, type_msg, caps),
                .reverse_eng => try output.printWarning(w, type_msg, caps),
                .unknown => {},
            }
        }
    } else {
        try output.printWarning(w, i18n.tr(lang, "Could not detect models (auth may be required)", "无法检测模型（可能需要认证）", "モデルを検出できません（認証が必要な場合があります）"), caps);
    }

    // Model call test
    const model = tool_model;
    try output.printInfo(w, i18n.tr(lang, "Testing model call...", "正在测试模型调用...", "モデル呼び出しをテスト中..."), caps);
    try w.flush();

    const call_result = check_mod.testModelCall(allocator, updated_site.base_url, updated_site.api_key, model, target_type);

    // Report model list presence
    if (call_result.model_in_list) {
        var list_buf: [128]u8 = undefined;
        const list_msg = std.fmt.bufPrint(&list_buf, "{s} '{s}' {s}", .{
            i18n.tr(lang, "Model", "模型", "モデル"),
            model,
            i18n.tr(lang, "found in model list", "在模型列表中", "はモデルリストに存在"),
        }) catch "Model in list";
        try output.printSuccess(w, list_msg, caps);
    } else {
        var list_buf: [128]u8 = undefined;
        const list_msg = std.fmt.bufPrint(&list_buf, "{s} '{s}' {s}", .{
            i18n.tr(lang, "Model", "模型", "モデル"),
            model,
            i18n.tr(lang, "not found in model list", "不在模型列表中", "はモデルリストに未検出"),
        }) catch "Model not in list";
        try output.printWarning(w, list_msg, caps);
    }

    // Report call result
    if (call_result.success) {
        var call_buf: [128]u8 = undefined;
        const latency_str = if (call_result.latency_ms) |ms| blk: {
            var lat_buf: [32]u8 = undefined;
            break :blk std.fmt.bufPrint(&lat_buf, " ({d}ms)", .{ms}) catch "";
        } else "";
        const call_msg = std.fmt.bufPrint(&call_buf, "{s} '{s}' {s}{s}", .{
            i18n.tr(lang, "Model", "模型", "モデル"),
            model,
            i18n.tr(lang, "is callable", "可以调用", "は呼び出し可能"),
            latency_str,
        }) catch "Model callable";
        try output.printSuccess(w, call_msg, caps);
    } else {
        var call_buf: [256]u8 = undefined;
        const err_detail = call_result.error_msg orelse i18n.tr(lang, "Unknown error", "未知错误", "不明なエラー");
        const call_msg = std.fmt.bufPrint(&call_buf, "{s} '{s}': {s}", .{
            i18n.tr(lang, "Model call failed", "模型调用失败", "モデル呼び出し失敗"),
            model,
            err_detail,
        }) catch "Model call failed";
        try output.printWarning(w, call_msg, caps);
    }

    try output.printSeparator(w, caps);
    try w.flush();
}

// --- Set ---

fn runSet(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, args: cli.SetArgs) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Settings", "设置", "設定"), caps);

    var settings = sites_mod.loadSettings(allocator);

    const key = args.key;
    const value = args.value;

    // Parse boolean value
    const bool_val = if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"))
        true
    else if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0"))
        false
    else {
        try output.printError(w, i18n.tr(lang, "Invalid value. Use on/off, true/false, or 1/0", "无效值，请使用 on/off、true/false 或 1/0", "無効な値です。on/off、true/false、1/0 を使用してください"), caps);
        try w.flush();
        return;
    };

    if (std.mem.eql(u8, key, "model_check")) {
        settings.model_check = bool_val;
    } else if (std.mem.eql(u8, key, "list_latency")) {
        settings.list_latency = bool_val;
    } else if (std.mem.eql(u8, key, "auto_archive")) {
        settings.auto_archive = bool_val;
    } else if (std.mem.eql(u8, key, "auto_pick_compatible_model")) {
        settings.auto_pick_compatible_model = bool_val;
    } else {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "{s}: '{s}'. {s}: model_check, list_latency, auto_archive, auto_pick_compatible_model", .{
            i18n.tr(lang, "Unknown setting", "未知设置项", "不明な設定"),
            key,
            i18n.tr(lang, "Available", "可用", "利用可能"),
        }) catch "Unknown setting";
        try output.printError(w, err_msg, caps);
        try w.flush();
        return;
    }

    try sites_mod.saveSettings(allocator, settings);

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{s} = {s}", .{
        key,
        if (bool_val) "on" else "off",
    }) catch "Updated";
    try output.printSuccess(w, msg, caps);

    // Show all current settings
    try output.printKeyValue(w, "  model_check:", if (settings.model_check) "on" else "off", caps);
    try output.printKeyValue(w, "  list_latency:", if (settings.list_latency) "on" else "off", caps);
    try output.printKeyValue(w, "  auto_archive:", if (settings.auto_archive) "on" else "off", caps);
    try output.printKeyValue(w, "  auto_pick_compatible_model:", if (settings.auto_pick_compatible_model) "on" else "off", caps);
    try w.flush();
}

// --- Models ---

fn runModels(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, args: cli.ModelsArgs) !void {
    var store = try sites_mod.loadSites(allocator);
    defer store.deinit(allocator);

    const site = store.getSite(args.alias) orelse {
        // Fuzzy match suggestion
        if (findClosestAlias(&store, args.alias)) |suggestion| {
            var suggest_buf: [256]u8 = undefined;
            const suggest_msg = std.fmt.bufPrint(&suggest_buf, "{s} '{s}' {s}. {s} '{s}'? [Y/n]", .{
                i18n.tr(lang, "Site", "站点", "サイト"),
                args.alias,
                i18n.tr(lang, "not found", "未找到", "が見つかりません"),
                i18n.tr(lang, "Did you mean", "你是否想输入", "もしかして"),
                suggestion,
            }) catch "Site not found";
            try output.printWarning(w, suggest_msg, caps);
            try w.flush();
            const answer = readLine();
            if (answer.len == 0 or answer[0] == 'y' or answer[0] == 'Y') {
                const corrected_args = cli.ModelsArgs{ .alias = suggestion };
                return runModels(allocator, w, caps, lang, corrected_args);
            }
        } else {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Site '{s}' not found", .{args.alias}) catch "Site not found";
            try output.printError(w, err_msg, caps);
        }
        try w.flush();
        return;
    };

    var header_buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} '{s}'", .{
        i18n.tr(lang, "Models for", "模型列表", "モデル一覧"),
        args.alias,
    }) catch i18n.tr(lang, "Models", "模型", "モデル");
    try output.printSectionHeader(w, header, caps);

    try output.printInfo(w, i18n.tr(lang, "Fetching model list...", "正在获取模型列表...", "モデルリストを取得中..."), caps);
    try w.flush();

    const model_list = check_mod.fetchModelList(allocator, site.base_url, site.api_key) catch {
        try output.printError(w, i18n.tr(lang, "Failed to fetch model list", "获取模型列表失败", "モデルリストの取得に失敗しました"), caps);
        try w.flush();
        return;
    };
    defer {
        for (model_list) |m| allocator.free(m);
        allocator.free(model_list);
    }

    if (model_list.len == 0) {
        try output.printWarning(w, i18n.tr(lang, "No models found", "未找到模型", "モデルが見つかりません"), caps);
        try w.flush();
        return;
    }

    var count_buf: [64]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&count_buf, "{d} {s}", .{
        model_list.len,
        i18n.tr(lang, "models available", "个可用模型", "個のモデルが利用可能"),
    }) catch "Models found";
    try output.printSuccess(w, count_msg, caps);

    const effective_model = site.effectiveModel();
    for (model_list) |model_id| {
        const is_current = std.mem.eql(u8, model_id, effective_model);
        if (is_current) {
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "  {s}{s} {s} *{s}", .{
                if (caps.color) output.Color.miku_green else "",
                if (caps.unicode) "●" else "*",
                model_id,
                if (caps.color) output.Color.reset else "",
            }) catch model_id;
            try w.print("{s}\n", .{line});
        } else {
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "  {s}{s} {s}{s}", .{
                if (caps.color) output.Color.miku_gray else "",
                if (caps.unicode) "○" else "-",
                model_id,
                if (caps.color) output.Color.reset else "",
            }) catch model_id;
            try w.print("{s}\n", .{line});
        }
    }

    try output.printSeparator(w, caps);
    try w.flush();
}

// --- Install / Uninstall ---

fn runInstall(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Install", "安装", "インストール"), caps);
    try w.flush();

    const result = install_mod.install(allocator) catch |err| {
        try output.printError(w, i18n.tr(lang, "Install failed", "安装失败", "インストールに失敗しました"), caps);
        try w.flush();
        return err;
    };
    defer allocator.free(result.path);

    switch (result.status) {
        .installed => try output.printSuccess(w, i18n.tr(lang, "Installed successfully", "安装成功", "インストールしました"), caps),
        .already_installed => try output.printInfo(w, i18n.tr(lang, "Already installed", "已经安装", "既にインストールされています"), caps),
        .already_installed_busy => try output.printWarning(w, i18n.tr(lang, "Already installed (existing binary is in use, kept current install)", "已经安装（现有程序正在使用，保留当前安装）", "既にインストール済みです（既存バイナリ使用中のため現行インストールを維持しました）"), caps),
    }
    try output.printKeyValue(w, i18n.tr(lang, "Executable:", "可执行文件:", "実行ファイル:"), result.path, caps);
    try output.printKeyValue(w, i18n.tr(lang, "PATH:", "PATH:", "PATH:"), app.display_install_bin_path, caps);
    try w.flush();
}

fn runUninstall(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Uninstall", "卸载", "アンインストール"), caps);
    try w.flush();

    const status = install_mod.uninstall(allocator) catch |err| {
        try output.printError(w, i18n.tr(lang, "Uninstall failed", "卸载失败", "アンインストールに失敗しました"), caps);
        try w.flush();
        return err;
    };

    switch (status) {
        .removed => try output.printSuccess(w, i18n.tr(lang, "Uninstalled successfully", "卸载完成", "アンインストールしました"), caps),
        .already_removed => try output.printInfo(w, i18n.tr(lang, "Already uninstalled", "已经卸载", "既にアンインストールされています"), caps),
        .scheduled_cleanup => try output.printWarning(w, i18n.tr(lang, "Uninstall scheduled in background. Wait a few seconds before reinstalling.", "已在后台安排卸载，重新安装前请等待几秒。", "バックグラウンドでアンインストールを開始しました。再インストール前に数秒待ってください。"), caps),
    }
    try w.flush();
}

// --- Version ---

fn runVersion(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    // Print version only - clean single line
    var ver_buf: [128]u8 = undefined;
    const ver_msg = std.fmt.bufPrint(&ver_buf, "VELORA v{s} - {s}", .{
        version,
        i18n.tr(lang, "Multi-Site API Key Manager", "多站点 API Key 管理器", "マルチサイト APIキー マネージャー"),
    }) catch version;
    try output.printInfo(w, ver_msg, caps);
    try w.flush();

    // Silently check for updates - only show if new version exists
    const info = update_mod.checkLatestVersion(allocator, version) catch {
        return;
    };
    defer {
        if (info.latest_version) |v| allocator.free(v);
        if (info.download_url) |u| allocator.free(u);
    }

    if (info.has_update) {
        const latest = info.latest_version orelse "?";
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} v{s} {s} (velora --update)", .{
            i18n.tr(lang, "New version available:", "有新版本:", "新バージョンあり:"),
            latest,
            i18n.tr(lang, "available", "待更新", "利用可能"),
        }) catch "New version available";
        try output.printWarning(w, msg, caps);
        try w.flush();
    }
    // No output when already up to date - version line is enough
}

// --- Update ---

fn runUpdate(allocator: std.mem.Allocator, w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) !void {
    try output.printSectionHeader(w, i18n.tr(lang, "Update", "更新", "アップデート"), caps);
    try output.printInfo(w, i18n.tr(lang, "Checking for updates...", "正在检查更新...", "アップデートを確認中..."), caps);
    try w.flush();

    const info = update_mod.checkLatestVersion(allocator, version) catch {
        try output.printError(w, i18n.tr(lang, "Failed to check for updates", "检查更新失败", "アップデートの確認に失敗しました"), caps);
        try w.flush();
        return;
    };
    defer {
        if (info.latest_version) |v| allocator.free(v);
        if (info.download_url) |u| allocator.free(u);
    }

    if (!info.has_update) {
        var msg_buf: [64]u8 = undefined;
        const latest = info.latest_version orelse version;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} ({s})", .{
            i18n.tr(lang, "Already up to date", "已是最新版本", "最新版です"),
            latest,
        }) catch i18n.tr(lang, "Already up to date", "已是最新版本", "最新版です");
        try output.printSuccess(w, msg, caps);
        try w.flush();
        return;
    }

    const latest = info.latest_version orelse "?";
    var msg_buf: [128]u8 = undefined;
    const found_msg = std.fmt.bufPrint(&msg_buf, "{s}: v{s} -> v{s}", .{
        i18n.tr(lang, "New version available", "发现新版本", "新バージョンが利用可能"),
        version,
        latest,
    }) catch "New version found";
    try output.printInfo(w, found_msg, caps);

    if (info.download_url) |url| {
        try output.printInfo(w, i18n.tr(lang, "Downloading update...", "正在下载更新...", "アップデートをダウンロード中..."), caps);
        try w.flush();

        update_mod.performUpdate(allocator, url) catch {
            try output.printError(w, i18n.tr(lang, "Update failed. Please download manually.", "更新失败，请手动下载", "アップデートに失敗しました。手動でダウンロードしてください"), caps);
            try w.flush();
            return;
        };
        try output.printSuccess(w, i18n.tr(lang, "Update complete! Restart to use new version.", "更新完成！重启以使用新版本", "アップデート完了！再起動して新バージョンをご利用ください"), caps);
    } else {
        try output.printWarning(w, i18n.tr(lang, "No binary found for this platform. Visit GitHub to download.", "未找到本平台的二进制文件，请前往 GitHub 下载", "このプラットフォーム用バイナリが見つかりません。GitHubからダウンロードしてください"), caps);
    }
    try w.flush();
}

// --- Interactive helpers ---

// Persistent buffers for interactive input so returned slices remain valid
// until the next call to the same function.
var g_readline_buf: [512]u8 = undefined;
var g_url_input_buf: [512]u8 = undefined;
var g_key_input_buf: [512]u8 = undefined;
var g_model_input_buf: [512]u8 = undefined;

fn bufCopy(buf: []u8, src: []const u8) []const u8 {
    const len = @min(src.len, buf.len);
    @memcpy(buf[0..len], src[0..len]);
    return buf[0..len];
}

fn readLine() []const u8 {
    return readLineInto(&g_readline_buf);
}

fn readLineInto(buf: *[512]u8) []const u8 {
    var stdin = std.fs.File.stdin();
    var len: usize = 0;
    while (len < buf.len) {
        var byte_buf: [1]u8 = undefined;
        const n = stdin.read(&byte_buf) catch 0;
        if (n == 0) break;
        const ch = byte_buf[0];
        if (ch == '\n') break;
        if (ch == '\r') continue;
        buf[len] = ch;
        len += 1;
    }
    return std.mem.trim(u8, buf[0..len], " \t");
}

fn askSiteType(w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language) ?sites_mod.SiteType {
    output.printInfo(w, i18n.tr(lang, "Choose type:", "选择类型:", "タイプを選択:"), caps) catch {};
    output.printMenuItem(w, 1, "Codex (cx)", caps) catch {};
    output.printMenuItem(w, 2, "Claude Code (cc)", caps) catch {};
    output.printMenuItem(w, 3, "OpenCode (oc)", caps) catch {};
    output.printMenuItem(w, 4, "Nanobot (nb)", caps) catch {};
    output.printMenuItem(w, 5, "OpenClaw (ow)", caps) catch {};
    output.printPrompt(w, i18n.tr(lang, "[1/2/3/4/5]:", "[1/2/3/4/5]:", "[1/2/3/4/5]:"), caps) catch {};
    w.flush() catch {};

    const input = readLine();
    if (input.len == 0) return null; // Enter = keep current
    if (std.mem.eql(u8, input, "1") or std.mem.eql(u8, input, "cx")) return .cx;
    if (std.mem.eql(u8, input, "2") or std.mem.eql(u8, input, "cc")) return .cc;
    if (std.mem.eql(u8, input, "3") or std.mem.eql(u8, input, "oc")) return .oc;
    if (std.mem.eql(u8, input, "4") or std.mem.eql(u8, input, "nb")) return .nb;
    if (std.mem.eql(u8, input, "5") or std.mem.eql(u8, input, "ow")) return .ow;
    return null;
}

fn askBaseUrl(w: *std.Io.Writer, caps: terminal.TermCaps, _: i18n.Language, current: ?[]const u8) []const u8 {
    if (current) |cur| {
        var prompt_buf: [256]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "Base URL [{s}]:", .{cur}) catch "Base URL:";
        output.printPrompt(w, prompt, caps) catch {};
    } else {
        output.printPrompt(w, "Base URL:", caps) catch {};
    }
    w.flush() catch {};

    const input = readLineInto(&g_url_input_buf);
    if (input.len == 0) {
        return current orelse "";
    }
    return input;
}

fn askApiKey(w: *std.Io.Writer, caps: terminal.TermCaps, _: i18n.Language, current: ?[]const u8) []const u8 {
    if (current) |cur| {
        var masked_buf: [64]u8 = undefined;
        const masked = sites_mod.maskKey(&masked_buf, cur);
        var prompt_buf: [128]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "API Key [{s}]:", .{masked}) catch "API Key:";
        output.printPrompt(w, prompt, caps) catch {};
    } else {
        output.printPrompt(w, "API Key:", caps) catch {};
    }
    w.flush() catch {};

    const input = readLineInto(&g_key_input_buf);
    if (input.len == 0) {
        return current orelse "";
    }
    return input;
}

fn askModel(w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, site_type: sites_mod.SiteType, current: ?[]const u8) []const u8 {
    const default_model = sites_mod.defaultModelForType(site_type);
    const display = if (current != null and current.?.len > 0) current.? else default_model;
    var prompt_buf: [256]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "{s} [{s}]:", .{
        i18n.tr(lang, "Model", "模型", "モデル"),
        display,
    }) catch "Model:";
    output.printPrompt(w, prompt, caps) catch {};
    w.flush() catch {};

    const input = readLineInto(&g_model_input_buf);
    if (input.len == 0) {
        return current orelse default_model;
    }
    return input;
}

fn printProbeSummary(w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, probe: check_mod.AddProbeResult) !void {
    try output.printInfo(w, i18n.tr(lang, "Probe summary:", "探测结果:", "プローブ結果:"), caps);
    var url_buf: [512]u8 = undefined;
    const url_msg = std.fmt.bufPrint(&url_buf, "  Base URL: {s}", .{probe.normalized_base_url}) catch probe.normalized_base_url;
    try output.printInfo(w, url_msg, caps);
    var models_buf: [128]u8 = undefined;
    const models_msg = std.fmt.bufPrint(&models_buf, "  Models: {d}", .{probe.model_count}) catch "Models";
    try output.printInfo(w, models_msg, caps);
    var provider_buf: [128]u8 = undefined;
    const provider_msg = std.fmt.bufPrint(&provider_buf, "  {s}: {s}", .{
        i18n.tr(lang, "Provider", "站点类型", "プロバイダー"),
        probe.provider_type.displayName(lang),
    }) catch "Provider";
    try output.printInfo(w, provider_msg, caps);

    inline for ([_]sites_mod.SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        if (check_mod.probeHasTool(probe, tool)) {
            var tool_buf: [256]u8 = undefined;
            const model = check_mod.probeRecommendedModel(probe, tool) orelse sites_mod.defaultModelForType(tool);
            const tool_msg = std.fmt.bufPrint(&tool_buf, "  {s}: {s}", .{ tool.displayName(), model }) catch tool.displayName();
            try output.printSuccess(w, tool_msg, caps);
        }
    }
    try w.flush();
}

fn askDefaultTools(w: *std.Io.Writer, caps: terminal.TermCaps, lang: i18n.Language, probe: check_mod.AddProbeResult, buf: *[5]sites_mod.SiteType) []const sites_mod.SiteType {
    const recommended = check_mod.probeRecommendedTools(probe, buf);
    output.printInfo(w, i18n.tr(lang, "Choose default tools (comma separated numbers, Enter = recommended):", "选择默认工具（逗号分隔数字，回车=推荐）:", "デフォルトツールを選択してください（カンマ区切り、Enter=推奨）:"), caps) catch {};
    var idx: u8 = 1;
    inline for ([_]sites_mod.SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        if (check_mod.probeHasTool(probe, tool)) {
            output.printMenuItem(w, idx, tool.displayName(), caps) catch {};
        }
        idx += 1;
    }
    output.printPrompt(w, i18n.tr(lang, "Selection:", "选择:", "選択:"), caps) catch {};
    w.flush() catch {};

    const input = readLine();
    if (input.len == 0) return recommended;

    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, input, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const n = std.fmt.parseInt(u8, trimmed, 10) catch continue;
        const tool = switch (n) {
            1 => sites_mod.SiteType.cx,
            2 => sites_mod.SiteType.cc,
            3 => sites_mod.SiteType.oc,
            4 => sites_mod.SiteType.nb,
            5 => sites_mod.SiteType.ow,
            else => continue,
        };
        if (!check_mod.probeHasTool(probe, tool)) continue;
        var exists = false;
        for (buf[0..count]) |t| {
            if (t == tool) exists = true;
        }
        if (!exists) {
            buf[count] = tool;
            count += 1;
        }
    }
    if (count == 0) return recommended;
    return buf[0..count];
}

fn applyProbeDefaults(site: *sites_mod.Site, probe: check_mod.AddProbeResult, selected_tools: []const sites_mod.SiteType) void {
    sites_mod.setDefaultTools(site, selected_tools);
    site.site_type = if (selected_tools.len > 0) selected_tools[0] else check_mod.probeSuggestedSiteType(probe);
    site.model = check_mod.probeRecommendedModel(probe, site.site_type) orelse sites_mod.defaultModelForType(site.site_type);
    inline for ([_]sites_mod.SiteType{ .cx, .cc, .oc, .nb, .ow }) |tool| {
        const model = check_mod.probeRecommendedModel(probe, tool) orelse "";
        switch (tool) {
            .cx => site.models_cx = model,
            .cc => site.models_cc = model,
            .oc => site.models_oc = model,
            .nb => site.models_nb = model,
            .ow => site.models_ow = model,
        }
    }
    sites_mod.ensureSelectionState(site);
}

test {
    _ = @import("sites.zig");
    _ = @import("config.zig");
}

// --- Fuzzy matching ---

fn editDistance(a: []const u8, b: []const u8) usize {
    const max_len = 64;
    if (a.len > max_len or b.len > max_len) return @max(a.len, b.len);
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    var prev: [max_len + 1]usize = undefined;
    var curr: [max_len + 1]usize = undefined;

    for (0..b.len + 1) |j| {
        prev[j] = j;
    }

    for (0..a.len) |i| {
        curr[0] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }

    return prev[b.len];
}

fn findClosestAlias(store: *const sites_mod.SitesStore, input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;

    const threshold = @max(1, input.len / 3);
    var best_dist: usize = threshold + 1;
    var best_alias: ?[]const u8 = null;

    for (0..store.count) |i| {
        const alias = store.entries[i].alias;
        const dist = editDistance(input, alias);
        if (dist < best_dist) {
            best_dist = dist;
            best_alias = alias;
        }
    }

    return best_alias;
}

test "edit distance" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), editDistance("abc", "abc"));
    try testing.expectEqual(@as(usize, 1), editDistance("abc", "ab"));
    try testing.expectEqual(@as(usize, 1), editDistance("abc", "abx"));
    try testing.expectEqual(@as(usize, 3), editDistance("abc", "xyz"));
    try testing.expectEqual(@as(usize, 1), editDistance("anyrouter", "anyouter"));
    try testing.expectEqual(@as(usize, 3), editDistance("", "abc"));
    try testing.expectEqual(@as(usize, 3), editDistance("abc", ""));
}
