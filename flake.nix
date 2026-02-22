{
  description = "RDS: consolidated system service for database engines (PostgreSQL, TypeDB, …)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.rds = import ./nix/rds.nix;
  };
}
