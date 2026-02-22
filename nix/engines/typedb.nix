# TypeDB engine for RDS.

{ config, lib, pkgs, ... }:

with lib;

let
  engine = import ../engine.nix { inherit lib; };
  cfg = config.services.rds.engines.typedb;
in
{
  options.services.rds.engines.typedb = engine.mkEngineOptions {
    name = "typedb";
    defaults = {
      port = 1729;
      dataDir = "/var/lib/rds/typedb";
      listenAddress = "127.0.0.1";
      description = "TypeDB";
    };
    extraOptions = {
      package = mkOption {
        type = types.package;
        description = "TypeDB package to use.";
      };
    };
  };

  config = mkIf cfg.enable {
    services.rds.engines._registered = [ "typedb" ];
    services.rds.engines.typedb.actions.connect =
      "typedb console --port=${toString cfg.port} --address=${cfg.listenAddress}";

    systemd.services.rds-typedb = {
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
  };
}
