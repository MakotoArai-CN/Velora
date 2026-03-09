const builtin = @import("builtin");

pub const display_name = "Velora";
pub const command_name = "velora";
pub const config_dir_name = ".velora";
pub const binding_filename = "velora.conf";

pub const legacy_command_name = "apikey-sync";
pub const legacy_config_dir_name = ".codex";
pub const legacy_binding_filename = "apikey-sync.conf";

pub const subtitle_en = "OpenAI API Key Orchestrator";
pub const subtitle_zh = "OpenAI API Key 编排器";
pub const subtitle_ja = "OpenAI APIキー オーケストレーター";

pub const auth_json_filename = "auth.json";
pub const config_toml_filename = "config.toml";
pub const install_bin_dir_name = "bin";
pub const path_marker = "# velora PATH";

pub fn executableName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => command_name ++ ".exe",
        else => command_name,
    };
}

pub fn launchAgentName() []const u8 {
    return "com." ++ command_name ++ ".plist";
}

