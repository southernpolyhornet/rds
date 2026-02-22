# PostgreSQL engine for RDS.

{ config, lib, pkgs, ... }:

with lib;

let
  engine = import ../engine.nix { inherit lib; };
  cfg = config.services.rds.engines.postgres;
  finalPackage = cfg.package.withPackages cfg.extensions;
in
{
  options.services.rds.engines.postgres = engine.mkEngineOptions {
    name = "postgres";
    defaults = {
      port = 5432;
      dataDir = "/var/lib/rds/postgres";
      listenAddress = "127.0.0.1";
      description = "PostgreSQL";
    };
    extraOptions = {
      package = mkOption {
        type = types.package;
        default = pkgs.postgresql;
        defaultText = literalExpression "pkgs.postgresql";
        description = "PostgreSQL package to use.";
      };
      extensions = mkOption {
        type = types.functionTo (types.listOf types.package);
        default = _: [ ];
        description = "Extension packages via postgresql.withPackages.";
        example = literalExpression "ps: [ ps.pgvector ps.postgis ]";
      };
      superuser = mkOption {
        type = types.str;
        default = "postgres";
        description = "Superuser name for initdb and connections.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to file containing the superuser password.";
      };
      authentication = mkOption {
        type = types.enum [ "trust" "scram-sha-256" "md5" ];
        default = "trust";
        description = "Default auth method for pg_hba.conf host connections.";
      };
    };
  };

  config = mkIf cfg.enable {
    services.rds.engines._registered = [ "postgres" ];
    services.rds.engines.postgres.actions.connect =
      let passEnv = optionalString (cfg.passwordFile != null) "PGPASSFILE=${escapeShellArg cfg.passwordFile} ";
      in "${passEnv}psql -h ${cfg.listenAddress} -p ${toString cfg.port} -U ${cfg.superuser}";

    systemd.services.rds-postgres = {
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
  };
}
