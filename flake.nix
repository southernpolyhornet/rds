{
  description = "RDS: consolidated system service for database engines (PostgreSQL, TypeDB, …)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.rds = import ./modules/rds.nix;
    # Use: imports = [ rds.nixosModules.rds ];
    #      services.rds = { enable = true; engines.postgres.enable = true; };
  };
}
