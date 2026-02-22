{
  description = "RDS: consolidated system service for database engines (PostgreSQL, TypeDB, …)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
  in {
    nixosModules.rds = import ./nix/rds.nix;
    nixosConfigurations.minimal = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.rds
        {
          services.rds.enable = true;
          services.rds.engines.postgres.enable = true;
          # Minimal config required for nixosSystem evaluation.
          fileSystems."/".device = "/dev/null";
          boot.loader.grub.devices = [ "/dev/null" ];
          system.stateVersion = "24.11";
        }
      ];
    };
    checks.${system}.minimal = self.nixosConfigurations.minimal.config.system.build.toplevel;
  };
}
