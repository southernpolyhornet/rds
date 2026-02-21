# TypeDB engine for RDS: common interface + rds-typedb.service.

{ config, lib, pkgs, ... }:

with lib;

let
  rdsLib = import ../lib/rds-engine.nix { inherit lib; };
  cfg = config.services.rds.engines.typedb;
  serviceName = rdsLib.serviceName "typedb";
in
{
  options.services.rds.engines.typedb = rdsLib.mkEngineOptions {
    name = "typedb";
    defaults = {
      port = 1729;
      dataDir = "/var/lib/rds/typedb";
      connectCommand = "";
      listenAddress = "127.0.0.1";
      description = "TypeDB";
    };
    extraOptions = {
      package = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "TypeDB package. Set to enable the server.";
      };
    };
  };

  config = mkIf (config.services.rds.enable or false) (mkMerge [
    (mkIf cfg.enable (mkIf (cfg.package != null) (let
      backupDir = if (cfg.backup.directory or "") != "" then cfg.backup.directory else "${cfg.dataDir}/backups";
      keep = toString (cfg.backup.keep or 7);
      backupScript = pkgs.writeShellScript "rds-backup-typedb" ''
        set -e
        BACKUP_DIR="${backupDir}"
        DATA_DIR="${cfg.dataDir}"
        KEEP="${keep}"
        case "''${1:-}" in
          backup)
            mkdir -p "$BACKUP_DIR"
            stamp="$(date -Iseconds | tr -d ':')"
            tar -czf "$BACKUP_DIR/$stamp.tar.gz" -C "$DATA_DIR" .
            cd "$BACKUP_DIR" && ls -t *.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f --
            ;;
          list)
            ls -1 "$BACKUP_DIR" 2>/dev/null | sed 's/\.tar\.gz$//' || true
            ;;
          restore)
            id="''${2:?Usage: restore <backup-id>}"
            if [ ! -f "$BACKUP_DIR/$id.tar.gz" ]; then echo "Backup not found: $id" >&2; exit 1; fi
            echo "Stop rds-typedb first for consistent restore (systemctl stop rds-typedb)." >&2
            mkdir -p "$DATA_DIR"
            tar -xzf "$BACKUP_DIR/$id.tar.gz" -C "$DATA_DIR"
            ;;
          *) echo "Usage: $0 backup | list | restore <backup-id>" >&2; exit 1 ;;
        esac
      '';
    in {
      services.rds.registeredEngines = [ "typedb" ];
      services.rds.engines.typedb.connectCommand = mkDefault
        "typedb console --port=${toString cfg.port} --address=${cfg.listenAddress}";
      services.rds.engines.typedb.version = mkDefault (cfg.package.version or null);
      services.rds.engines.typedb.backup.directory = mkDefault "${cfg.dataDir}/backups";
      services.rds.backupScripts.typedb = mkIf (cfg.backup.enable or false) backupScript;

      systemd.services.${serviceName} = {
        description = "RDS ${cfg.description}";
        wantedBy = [ "rds.target" ];
        after = [ "network.target" ];
        path = [ cfg.package ];
        environment = cfg.extraEnv // { TYPEDB_DATA_DIR = cfg.dataDir; };
        script = "exec typedb server --port=${toString cfg.port} --address=${cfg.listenAddress}";
        serviceConfig = {
          RuntimeDirectory = "rds-typedb";
          StateDirectory = "rds-typedb";
          Restart = "on-failure";
        };
      };
    })))
  ]);
}
