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
  };

  config = mkIf cfg.enable {
    systemd.targets.rds = {
      description = "RDS database engines";
      wantedBy = [ "multi-user.target" ];
    };
    environment.systemPackages = [ cli ];
  };
}
