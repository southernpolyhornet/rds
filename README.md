# RDS

One NixOS service for multiple database engines (PostgreSQL, TypeDB, …): single `rds.target`, unified `rds` CLI (start/stop, connect, backup/restore).

## Quick start

```nix
imports = [ inputs.rds.nixosModules.rds ];

services.rds = {
  enable = true;
  engines.postgres.enable = true;
};
```

## CLI

`rds start` | `stop` | `restart` | `status` · `rds connect <engine>` · `rds backup [list] <engine>` · `rds restore <engine> <id>`

## Dashboard

Optional web UI (one tab per engine: status, start/stop, backup, connect, browse). Don’t expose to the public; use `dashboard.passwordFile`, `dashboard.allowedOrigins`, and `listenAddress = "0.0.0.0"` for Tailnet/LAN. Default: http://127.0.0.1:8765

```nix
services.rds.dashboard = {
  enable = true;
  listenAddress = "0.0.0.0";
  passwordFile = "/run/keys/rds-dashboard-password";
  allowedOrigins = [ "http://rds:8765" "http://100.64.0.2:8765" ];
};
```

## Engines

**Postgres:** port 5432, `package`, `extensions`, `superuser`/`passwordFile`/`authentication`, optional `pgweb.enable` for browse.  
**TypeDB:** port 1729, `package` (required), set `browseUrl` if using TypeDB Studio.

## Backup

Per engine: `backup.enable`, `backup.schedule`, `backup.keep`, `backup.directory`. Timer runs automatically; manual: `rds backup <engine>`, `rds restore <engine> <id>`.

## Development

`nix flake check`; `mypy dashboard/`

## License

MIT — [LICENSE](LICENSE)
