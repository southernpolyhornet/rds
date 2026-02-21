# PostgreSQL engine for RDS: common interface + rds-postgres.service.
# Engine-specific options (credentialing, etc.) are in extraOptions; other engines ignore them.

{ config, lib, pkgs, ... }:

with lib;

let
  rdsLib = import ../lib/rds-engine.nix { inherit lib; };
  cfg = config.services.rds.engines.postgres;
  serviceName = rdsLib.serviceName "postgres";
in
{
  options.services.rds.engines.postgres = rdsLib.mkEngineOptions {
    name = "postgres";
    defaults = {
      port = 5432;
      dataDir = "/var/lib/rds/postgres";
      connectCommand = "";
      listenAddress = "127.0.0.1";
      description = "PostgreSQL";
    };
    extraOptions = {
      package = mkOption {
        type = types.package;
        default = pkgs.postgresql;
        defaultText = "pkgs.postgresql";
        description = "PostgreSQL package to run (e.g. pkgs.postgresql_17 for PG 17).";
      };
      extensions = mkOption {
        type = types.functionTo (types.listOf types.package);
        default = _: [ ];
        defaultText = "ps: []";
        description = ''
          Extension packages via postgresql.withPackages. Use the same major version as package.
          Example: extensions = ps: [ ps.pgvector ps.postgis ];
        '';
        example = literalExpression "ps: [ ps.pgvector ps.postgis ]";
      };
      # --- Postgres-only: credentialing ---------------------------------------
      superuser = mkOption {
        type = types.str;
        default = "postgres";
        description = "Superuser name (used by initdb and default connectCommand).";
      };
      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path to a file containing the superuser password (one line, no newline).
          Default connectCommand will use PGPASSFILE so "rds connect postgres" works.
        '';
        example = "/run/keys/postgres-superuser-password";
      };
      authentication = mkOption {
        type = types.enum [ "trust" "scram-sha-256" "md5" ];
        default = "trust";
        description = "Default auth method for pg_hba.conf (host connections).";
      };
      pgweb = {
        enable = mkEnableOption "pgweb for the dashboard browse tab";
        port = mkOption {
          type = types.port;
          default = 5050;
          description = "Port pgweb listens on (browseUrl will point here).";
        };
      };
    };
  };

  config = mkIf (config.services.rds.enable or false) (mkMerge [
    (mkIf cfg.enable (let
      finalPackage = cfg.package.withPackages cfg.extensions;
      backupDir = if (cfg.backup.directory or "") != "" then cfg.backup.directory else "${cfg.dataDir}/backups";
      keep = toString (cfg.backup.keep or 7);
      backupScript = pkgs.writeShellScript "rds-backup-postgres" ''
        set -e
        BACKUP_DIR="${backupDir}"
        KEEP="${keep}"
        export PGHOST="${cfg.listenAddress}" PGPORT="${toString cfg.port}" PGUSER="${cfg.superuser}"
        ${if cfg.passwordFile != null then "export PGPASSFILE=${escapeShellArg cfg.passwordFile};" else ""}
        export PATH="${finalPackage}/bin:''${PATH}"
        case "''${1:-}" in
          backup)
            mkdir -p "$BACKUP_DIR"
            stamp="$(date -Iseconds | tr -d ':')"
            pg_dump -Fc -f "$BACKUP_DIR/$stamp.dump"
            cd "$BACKUP_DIR" && ls -t *.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f --
            ;;
          list)
            ls -1 "$BACKUP_DIR" 2>/dev/null | sed 's/\.dump$//' || true
            ;;
          restore)
            id="''${2:?Usage: restore <backup-id>}"
            if [ ! -f "$BACKUP_DIR/$id.dump" ]; then echo "Backup not found: $id" >&2; exit 1; fi
            pg_restore -c -d postgres "$BACKUP_DIR/$id.dump" || true
            ;;
          *) echo "Usage: $0 backup | list | restore <backup-id>" >&2; exit 1 ;;
        esac
      '';
    in {
      services.rds.registeredEngines = [ "postgres" ];
      services.rds.engines.postgres.connectCommand = mkDefault (
        if cfg.passwordFile != null then
          "PGPASSFILE=${escapeShellArg cfg.passwordFile} psql -h ${cfg.listenAddress} -p ${toString cfg.port} -U ${cfg.superuser}"
        else
          "psql -h ${cfg.listenAddress} -p ${toString cfg.port} -U ${cfg.superuser}"
      );
      services.rds.engines.postgres.version = mkDefault (finalPackage.version or null);
      services.rds.engines.postgres.backup.directory = mkDefault "${cfg.dataDir}/backups";
      services.rds.backupScripts.postgres = mkIf (cfg.backup.enable or false) backupScript;
      services.rds.engines.postgres.browseUrl = mkIf (cfg.pgweb.enable or false) "http://${cfg.listenAddress}:${toString cfg.pgweb.port}";

      systemd.services.${serviceName} = {
        description = "RDS ${cfg.description}";
        wantedBy = [ "rds.target" ];
        after = [ "network.target" ];
        path = [ finalPackage ];
        environment = cfg.extraEnv // { PGDATA = cfg.dataDir; };
        script = ''
          if [ ! -f "$PGDATA/PG_VERSION" ]; then
            initdb -U ${cfg.superuser}
            echo "host all all 0.0.0.0/0 ${cfg.authentication}" >> "$PGDATA/pg_hba.conf"
            echo "listen_addresses = '${cfg.listenAddress}'" >> "$PGDATA/postgresql.conf"
          fi
          exec postgres -p ${toString cfg.port}
        '';
        serviceConfig = {
          User = "postgres";
          Group = "postgres";
          Restart = "on-failure";
        };
      };
      users.users.postgres = mkIf (cfg.dataDir == "/var/lib/rds/postgres") {
        isSystemUser = true;
        group = "postgres";
        home = cfg.dataDir;
        createHome = true;
      };
      users.groups.postgres = { };
      systemd.services.rds-pgweb-postgres = mkIf (cfg.pgweb.enable or false) {
        description = "pgweb for RDS PostgreSQL (dashboard browse)";
        after = [ "${serviceName}" ];
        wants = [ "${serviceName}" ];
        path = [ pkgs.pgweb ];
        environment = {
          PGHOST = cfg.listenAddress;
          PGPORT = toString cfg.port;
          PGUSER = cfg.superuser;
          PGDATABASE = "postgres";
        };
        serviceConfig = { Type = "simple"; Restart = "on-failure"; };
        script = ''
          ${if cfg.passwordFile != null then "export PGPASSWORD=$(cat ${escapeShellArg cfg.passwordFile})" else ""}
          exec pgweb --listen=:${toString cfg.pgweb.port}
        '';
      };
    }))
  ]);
}
