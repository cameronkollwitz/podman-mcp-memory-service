# podman-mcp-memory-service

A Podman compose stack that runs [doobidoo/mcp-memory-service](https://github.com/doobidoo/mcp-memory-service)
11.14.0 on Windows, with a logon task that starts it after a reboot. It gives Claude Code a
persistent memory server over MCP.

## What runs

Both containers use the same image, pinned by tag in `compose.yaml`.

| Container | Port | Env file | Purpose |
| --- | --- | --- | --- |
| `mcp-memory` | 8765 | `core.env` | MCP endpoint at `http://127.0.0.1:8765/mcp` (streamable HTTP) |
| `mcp-memory-ui` | 8000 | `ui.env` | `memory server --http`: the web dashboard and REST API |

The storage backend is `hybrid`. Memories live in a SQLite database on the `mcp-memory` volume and
synchronize to Cloudflare D1 and Vectorize. Both containers share that volume and the `mcp-models`
model cache, and each has its own backups volume.

## Requirements

- Windows with Podman and a Podman machine, plus `podman compose`
- A Cloudflare account with a D1 database, a Vectorize index named `mcp-memory-index`, and an API
  token that can read and write both

## Setup

1. Copy the env templates and fill in every `<PLACEHOLDER>`:

   ```powershell
   Copy-Item core.env.example core.env
   Copy-Item ui.env.example ui.env
   ```

   Both files take the same Cloudflare account ID, D1 database ID, API token and `MCP_API_KEY`.
   `*.env` is in `.gitignore`, so the live files stay out of the repository.

2. Create the volumes. They are declared `external`, so compose will not create them:

   ```powershell
   'mcp-memory','mcp-models','mcp-backups-core','mcp-backups-ui' | ForEach-Object { podman volume create $_ }
   ```

3. Start the stack:

   ```powershell
   podman compose up -d
   ```

4. Register the server with Claude Code as a user-scoped HTTP server, sending the API key as a
   bearer token:

   ```powershell
   claude mcp add --scope user --transport http memory http://127.0.0.1:8765/mcp --header "Authorization: Bearer <MCP_API_KEY>"
   ```

## Start on logon

Podman has no daemon, so `restart: always` does not bring the containers back after a reboot.
`mcp-memory-autostart.ps1` installs a scheduled task that runs at logon, starts the Podman machine,
waits for it to respond and runs `podman compose up -d`. Each run appends to
`%LOCALAPPDATA%\mcp-memory-autostart.log`.

```powershell
.\mcp-memory-autostart.ps1 -Install -RunNow   # create the task and run it once
.\mcp-memory-autostart.ps1 -Status            # last run, result code, recent log lines
.\mcp-memory-autostart.ps1 -Uninstall         # remove the task
```

`-StackPath` points the task at a different folder, and `-TimeoutSeconds` sets how long it waits
for Podman (120 by default).

## Troubleshooting

```powershell
podman ps --format '{{.Names}} {{.Status}}'
podman logs mcp-memory --tail 50
.\mcp-memory-autostart.ps1 -Status
```

To upgrade, change the image tag in both services together, run `podman compose up -d`, and
confirm a search through the MCP server returns results.

## License

[MIT](LICENSE). The upstream image is licensed separately by its authors.
