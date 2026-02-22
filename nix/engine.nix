# Shared option constructor for RDS engines.
# Each engine calls mkEngineOptions to get a consistent set of options

{ lib }:

with lib;

{
  mkEngineOptions = { name, defaults, extraOptions ? { } }: {
    enable = mkEnableOption "${name} engine under RDS";
    port = mkOption {
      type = types.port;
      default = defaults.port or 0;
      description = "Port the engine listens on.";
    };
    dataDir = mkOption {
      type = types.str;
      default = defaults.dataDir or "/var/lib/rds/${name}";
      description = "Data directory for this engine.";
    };
    listenAddress = mkOption {
      type = types.str;
      default = defaults.listenAddress or "127.0.0.1";
      description = "Address the engine binds to.";
    };
    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables for the engine process.";
    };
    description = mkOption {
      type = types.str;
      default = defaults.description or name;
      description = "Human-readable label for this engine.";
    };

    actions = mkOption {
      type = types.attrsOf types.str;
      default = {
        start   = "systemctl start rds-${name}";
        stop    = "systemctl stop rds-${name}";
        restart = "systemctl restart rds-${name}";
        status  = "systemctl --no-pager status rds-${name}";
      };
      description = "Named shell commands this engine provides (start, stop, status, connect, …).";
    };
  } // extraOptions;
}
