# Common RDS engine interface: shared option shape and naming.
#
# Contract for each engine:
#   - Options: enable, port, dataDir, connectCommand, version, listenAddress, extraEnv, description,
#     backup.{ enable, schedule, keep, directory } (+ engine-specific via extraOptions).
#   - Engine-only options: add them in that engine's extraOptions (e.g. postgres: superuser, passwordFile).
#   - Systemd unit: rds-<name>.service (start/stop via systemctl or "rds start"/"rds stop").
#   - Connect: "rds connect <name>" runs the engine's connectCommand.
#   - Backup: when backup.enable, engine provides backup/restore script; RDS runs "backup now" on
#     backup.schedule, keeps backup.keep, stores under backup.directory; "rds backup <engine>" and
#     "rds restore <engine> <id>" call the engine implementation.
#
# Use mkEngineOptions in each engine to get a consistent option set.

{ lib }:

with lib;

{
  # Build option set for an engine: common options with defaults + extra options.
  # name: engine name (e.g. "postgres")
  # defaults: { port, dataDir, connectCommand, version?, listenAddress?, extraEnv?, description? }
  # extraOptions: attrset of additional option definitions (e.g. package)
  mkEngineOptions = { name, defaults, extraOptions ? { } }: {
    enable = mkEnableOption "this engine under RDS";
    port = mkOption {
      type = types.port;
      default = defaults.port or 0;
      defaultText = literalExpression (toString (defaults.port or 0));
      description = "Port the engine listens on.";
    };
    dataDir = mkOption {
      type = types.str;
      default = defaults.dataDir or "/var/lib/rds/${name}";
      defaultText = literalExpression ''"/var/lib/rds/${name}"'';
      description = "Data directory for this engine.";
    };
    connectCommand = mkOption {
      type = types.either types.str (types.listOf types.str);
      default = defaults.connectCommand or "echo 'no connect command'";
      defaultText = literalExpression ''"…"'';
      description = "Command for 'rds connect ${name}' (shell string or argv).";
      example = "psql -h 127.0.0.1 -p 5432 -U postgres";
    };
    version = mkOption {
      type = types.nullOr types.str;
      default = defaults.version or null;
      defaultText = literalExpression "null (or derived from package)";
      description = "Engine version string (e.g. for display, compatibility checks, or tooling).";
      example = "16.4";
    };
    listenAddress = mkOption {
      type = types.str;
      default = defaults.listenAddress or "127.0.0.1";
      defaultText = literalExpression ''"127.0.0.1"'';
      description = "Address the engine binds to (e.g. 127.0.0.1, 0.0.0.0 for all interfaces).";
      example = "0.0.0.0";
    };
    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = defaults.extraEnv or { };
      defaultText = literalExpression "{}";
      description = "Extra environment variables for the engine process.";
      example = literalExpression ''{ TZ = "UTC"; }'';
    };
    description = mkOption {
      type = types.str;
      default = defaults.description or name;
      defaultText = literalExpression ''"${name}"'';
      description = "Human-readable label for this engine (e.g. in status or tooling).";
    };
    browseUrl = mkOption {
      type = types.nullOr types.str;
      default = defaults.browseUrl or null;
      description = "URL for the web dashboard 'browse' tab (e.g. pgweb, TypeDB Studio). Shown in iframe when set.";
      example = "http://127.0.0.1:5050";
    };
    # Uniform backup contract: when to run, how many to keep, where. Engine implements the actual backup/restore.
    backup = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "automatic backups for this engine";
          schedule = mkOption {
            type = types.str;
            default = "daily";
            description = "When to run automatic backups: systemd calendar (e.g. \"daily\", \"*-*-* 02:00:00\") or cron-like.";
            example = "*-*-* 02:00:00";
          };
          keep = mkOption {
            type = types.ints.positive;
            default = 7;
            description = "Number of backups to retain (oldest pruned after each backup).";
          };
          directory = mkOption {
            type = types.str;
            default = "";
            defaultText = literalExpression ''"''${dataDir}/backups" (each engine sets mkDefault)'';
            description = "Directory to store backups (typically dataDir/backups).";
          };
        };
      };
      default = { };
      description = "Backup schedule and retention; engine implements backup now / restore to.";
    };
  } // extraOptions;

  serviceName = name: "rds-${name}";
}
