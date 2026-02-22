# RDS: consolidated NixOS module for database engines.
# Imports engine modules and provides the shared rds.target + CLI.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.rds;
  registered = cfg.engines._registered;
  
  engineDispatch = name:
    let
      actions = config.services.rds.engines.${name}.actions;
      cases = concatStringsSep "\n" (mapAttrsToList (action: cmd: ''
        ${action}) ${cmd} ;;'') actions);
      actionList = concatStringsSep "|" (attrNames actions);
    in pkgs.writeShellScript "rds-${name}-dispatch" ''
      case "''${1:-}" in
        ${cases}
        *) echo "${name}: unknown action ''${1:-}. Available: ${actionList}" >&2; exit 1 ;;
      esac
    '';

  dispatchers = listToAttrs (map (n: nameValuePair n (engineDispatch n)) registered);

  cli = pkgs.writeShellScriptBin "rds" ''
    set -euo pipefail

    action="''${1:-}"
    engine="''${2:-}"

    if [ -z "$action" ]; then
      echo "Usage: rds <action> [engine]"
      echo "Engines: ${concatStringsSep " " registered}"
      echo "Run 'rds <action>' to apply to all engines, or 'rds <action> <engine>' for one."
      exit 1
    fi

    run_engine() {
      local eng="$1" act="$2"
      case "$eng" in
        ${concatStringsSep "\n" (map (n: ''
        ${n}) ${dispatchers.${n}} "$act" ;;'') registered)}
        *) echo "Unknown engine: $eng. Available: ${concatStringsSep " " registered}" >&2; exit 1 ;;
      esac
    }

    if [ -n "$engine" ]; then
      run_engine "$engine" "$action"
    else
      for eng in ${concatStringsSep " " registered}; do
        echo "--- $eng ---"
        run_engine "$eng" "$action" || true
      done
    fi
  '';
in
{
  imports = [
    ./engines/postgres.nix
    ./engines/typedb.nix
  ];

  options.services.rds = {
    enable = mkEnableOption "consolidated RDS (database engines) target";
    engines._registered = mkOption {
      type = types.listOf types.str;
      default = [ ];
      internal = true;
      description = "Engine names registered by enabled engine modules.";
    };
    dashboard = {
      enable = mkEnableOption "web dashboard (status, start/stop per engine)";
      port = mkOption {
        type = types.port;
        default = 8765;
        description = "Port the dashboard listens on.";
      };
      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to bind. Use 0.0.0.0 for LAN/Tailnet access.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to file containing the dashboard password. Enables HTTP Basic auth.";
      };
      authUsername = mkOption {
        type = types.str;
        default = "rds";
        description = "HTTP Basic auth username when passwordFile is set.";
      };
      allowedOrigins = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "CORS allowed origins. Empty = same-origin only.";
      };
    };
  };

  config = mkIf cfg.enable (let
    dashCfg = cfg.dashboard;
    dashboardPackage = pkgs.runCommand "rds-dashboard" { } ''
      mkdir -p $out/static
      cp ${../dashboard/server.py} $out/server.py
      cp ${../dashboard/static/index.html} $out/static/index.html
    '';
  in mkMerge [
    {
      systemd.targets.rds = {
        description = "RDS database engines";
        wantedBy = [ "multi-user.target" ];
      };
      environment.systemPackages = [ cli ];
    }
    (mkIf dashCfg.enable {
      systemd.services.rds-dashboard = {
        description = "RDS web dashboard";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        path = [ cli ];
        environment = {
          RDS_ENGINES = concatStringsSep "," registered;
          RDS_DASHBOARD_HOST = dashCfg.listenAddress;
          RDS_DASHBOARD_PORT = toString dashCfg.port;
          RDS_DASHBOARD_AUTH_USER = dashCfg.authUsername;
          RDS_DASHBOARD_ALLOWED_ORIGINS = concatStringsSep "," dashCfg.allowedOrigins;
        };
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          DynamicUser = false;
        } // (optionalAttrs (dashCfg.passwordFile != null) {
          LoadCredential = [ "rds-dashboard-password:${dashCfg.passwordFile}" ];
        });
        script = ''
          ${optionalString (dashCfg.passwordFile != null) ''
            export RDS_DASHBOARD_PASSWORD_FILE="''${CREDENTIALS_DIRECTORY}/rds-dashboard-password"
          ''}
          cd ${dashboardPackage}
          exec ${pkgs.python3}/bin/python3 server.py
        '';
      };
    })
  ]);
}
