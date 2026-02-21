# Consolidated RDS (database engines) NixOS module.
# One system target (rds.target) starts all enabled engines; each engine adds rds-<name>.service.
# Unified CLI: rds start | stop | status | connect <engine> | backup <engine> | restore <engine> <id>.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rds;
  registered = config.services.rds.registeredEngines or [ ];
  wants = map (n: "rds-${n}.service") registered;
  backupScripts = config.services.rds.backupScripts or { };
  enginesWithBackup = filter (n: (config.services.rds.engines.${n}.backup.enable or false) && hasAttr n backupScripts) registered;

  dashboardPackage = pkgs.runCommand "rds-dashboard" { } ''
    mkdir -p $out/static
    cp ${../dashboard/server.py} $out/server.py
    cp ${../dashboard/static/index.html} $out/static/index.html
    chmod +x $out/server.py
  '';

  connectCommandStr = name:
    let cmd = (config.services.rds.engines.${name} or {}).connectCommand or "";
    in if isString cmd then cmd else concatStringsSep " " (map escapeShellArg cmd);

  # Per-engine connect script: set PATH (and optional PGPASSFILE), then run connect command.
  connectScript = name:
    let
      engineCfg = config.services.rds.engines.${name} or {};
      pkg = engineCfg.package or null;
      cmd = engineCfg.connectCommand or "echo 'no connect command'";
      pathPrefix = if pkg != null then "export PATH=\"${pkg}/bin:\''${PATH}\"; " else "";
      line = pathPrefix + (if isString cmd then cmd else "exec " + (concatStringsSep " " (map escapeShellArg cmd)));
    in
      pkgs.writeShellScript "rds-connect-${name}" line;

  connectScripts = listToAttrs (map (n: nameValuePair n (connectScript n)) registered);

  rdsCli = pkgs.writeShellScriptBin "rds" ''
    set -e
    case "''${1:-}" in
      start)   systemctl start rds.target ;;
      stop)    systemctl stop rds.target ;;
      restart) systemctl restart rds.target ;;
      status)
        systemctl --no-pager status rds.target 2>/dev/null || true
        for e in ${concatStringsSep " " (map escapeShellArg registered)}; do
          echo "--- rds-$e ---"
          systemctl --no-pager status "rds-$e.service" 2>/dev/null || true
        done
        ;;
      connect)
        engine="''${2:-}"
        case "$engine" in
          ${concatStringsSep "\n          " (map (n: ''
${n})
            exec ${connectScripts.${n}}
            ;;
          '') registered)}
          "")
            echo "Usage: rds connect <engine>"
            echo "Engines: ${concatStringsSep " " registered}"
            exit 1
            ;;
          *)
            echo "Unknown engine: $engine. Available: ${concatStringsSep " " registered}"
            exit 1
            ;;
        esac
        ;;
      backup)
        if [ "''${2:-}" = "list" ]; then backupCmd="list"; engine="''${3:-}"; else backupCmd="backup"; engine="''${2:-}"; fi
        case "$engine" in
          ${concatStringsSep "\n          " (map (n: ''
${n})
            exec ${backupScripts.${n}} "''$backupCmd"
            ;;
          '') enginesWithBackup)}
          "")
            echo "Usage: rds backup [list] <engine>"
            echo "Engines with backup: ${concatStringsSep " " enginesWithBackup}"
            exit 1
            ;;
          *)
            echo "Unknown engine or backup not enabled: $engine"
            exit 1
            ;;
        esac
        ;;
      restore)
        engine="''${2:-}"
        restoreId="''${3:-}"
        case "$engine" in
          ${concatStringsSep "\n          " (map (n: ''
${n})
            exec ${backupScripts.${n}} restore "''$restoreId"
            ;;
          '') enginesWithBackup)}
          "")
            echo "Usage: rds restore <engine> <backup-id>"
            echo "Engines with backup: ${concatStringsSep " " enginesWithBackup}"
            exit 1
            ;;
          *)
            echo "Unknown engine or backup not enabled: $engine"
            exit 1
            ;;
        esac
        ;;
      *)
        echo "Usage: rds { start | stop | restart | status | connect <engine> | backup [list] <engine> | restore <engine> <id> }"
        echo "Engines: ${concatStringsSep " " registered}"
        exit 1
        ;;
    esac
  '';
in
{
  imports = [
    ../engines/postgres.nix
    ../engines/typedb.nix
  ];

  options.services.rds = {
    enable = mkEnableOption "consolidated RDS (database engines) target";
    engines = mkOption {
      type = types.submodule { };
      default = { };
      description = "RDS engine configs (postgres, typedb, …).";
    };
    # Populated by each engine when enabled (mkMerge list).
    registeredEngines = mkOption {
      type = types.listOf types.str;
      default = [ ];
      internal = true;
      description = "List of enabled engine names for target wants and CLI.";
    };
    # Unified CLI for start/stop/status/connect/backup/restore. Add to systemPackages to use.
    cli = mkOption {
      type = types.package;
      default = rdsCli;
      defaultText = "rds CLI";
      description = "Package providing the 'rds' command.";
    };
    # Set by each engine that supports backup (path to script: backup | restore <id> | list).
    backupScripts = mkOption {
      type = types.attrsOf types.path;
      default = { };
      internal = true;
      description = "Per-engine backup/restore script (contract: backup, restore <id>, list).";
    };
    dashboard = {
      enable = mkEnableOption "web dashboard (one tab per engine: status, start/stop, backup, browse)";
      port = mkOption {
        type = types.port;
        default = 8765;
        description = "Port the dashboard listens on.";
      };
      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to bind. Use 0.0.0.0 to allow Tailnet/LAN (restrict with firewall + auth).";
      };
      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to file containing one line (password). If set, dashboard requires HTTP Basic auth (user from authUsername).";
        example = "/run/keys/rds-dashboard-password";
      };
      authUsername = mkOption {
        type = types.str;
        default = "rds";
        description = "HTTP Basic auth username when passwordFile is set.";
      };
      allowedOrigins = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          CORS allowed origins. Empty = same-origin only (browser only allows the dashboard URL).
          Add origins (e.g. http://hostname:8765, http://100.x.x.x:8765 for Tailnet) so other devices on your network can use the dashboard. Do not add public web origins.
        '';
        example = [ "http://rds:8765" "http://100.64.0.2:8765" ];
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      systemd.targets.rds = {
        description = "RDS database engines";
        wantedBy = [ "multi-user.target" ];
        wants = wants;
      };
      environment.systemPackages = [ cfg.cli ];
    }
    # Per-engine backup timer + oneshot when backup.enable and script registered
    (mkMerge (map (n:
      let
        engineCfg = config.services.rds.engines.${n};
        schedule = engineCfg.backup.schedule or "daily";
      in
      {
        systemd.services."rds-${n}-backup" = {
          description = "RDS backup for ${n}";
          after = [ "rds-${n}.service" ];
          wants = [ "rds-${n}.service" ];
          serviceConfig.Type = "oneshot";
          script = "${backupScripts.${n}} backup";
        };
        systemd.timers."rds-${n}-backup" = {
          description = "RDS automatic backup for ${n}";
          wantedBy = [ "timers.target" ];
          timerConfig.OnCalendar = schedule;
        };
      }
    ) enginesWithBackup))
    (mkIf (cfg.dashboard.enable or false) {
      systemd.services.rds-dashboard = {
        description = "RDS web dashboard";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        path = [ config.services.rds.cli ];
        environment = {
          RDS_ENGINES = concatStringsSep "," registered;
          RDS_BACKUP_ENGINES = concatStringsSep "," enginesWithBackup;
          RDS_DASHBOARD_HOST = cfg.dashboard.listenAddress;
          RDS_DASHBOARD_PORT = toString cfg.dashboard.port;
          RDS_DASHBOARD_AUTH_USER = cfg.dashboard.authUsername;
          RDS_DASHBOARD_ALLOWED_ORIGINS = concatStringsSep "," cfg.dashboard.allowedOrigins;
        }
        // listToAttrs (concatLists [
          (map (n: nameValuePair "RDS_BROWSE_${replaceStrings [ "-" ] [ "_" ] n}" (
            (config.services.rds.engines.${n} or {}).browseUrl or ""
          )) registered)
          (map (n: nameValuePair "RDS_CONNECT_${replaceStrings [ "-" ] [ "_" ] n}" (connectCommandStr n)) registered)
        ]);
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          DynamicUser = false;
        }
        // (if cfg.dashboard.passwordFile != null then {
          LoadCredential = [ "rds-dashboard-password:${cfg.dashboard.passwordFile}" ];
        } else { });
        script = ''
          ${if cfg.dashboard.passwordFile != null then ''
            export RDS_DASHBOARD_PASSWORD_FILE="''${CREDENTIALS_DIRECTORY}/rds-dashboard-password"
          '' else ""}
          cd ${dashboardPackage}
          exec ${pkgs.python3}/bin/python3 server.py
        '';
      };
    })
  ]);
}
