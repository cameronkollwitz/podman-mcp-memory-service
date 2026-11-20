# podman-mcp-memory-service

[![check](https://github.com/cameronkollwitz/podman-mcp-memory-service/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/cameronkollwitz/podman-mcp-memory-service/actions/workflows/check.yml)

A Podman compose stack that runs [doobidoo/mcp-memory-service](https://github.com/doobidoo/mcp-memory-service)
on Windows, with a logon task that starts it after a reboot. It gives Claude Code a persistent
memory server over MCP. The image is pinned by tag and digest in `compose.yaml`, and Dependabot
proposes each new version.

## What runs

Both containers use the same image, pinned by tag and digest in `compose.yaml`. Upstream deletes
old version tags from Docker Hub, and the digest keeps the pinned image pullable after its tag is
gone.

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

The task repairs three faults before it runs compose:

- **A connection file on the wrong port.** Podman run from an MSIX-packaged app, such as the Claude
  desktop app, writes `podman-connections.json` into the package's private copy of `%APPDATA%`, so
  a change to the machine's SSH port never reaches the real file. The task rewrites the machine's
  two connections to the port `podman machine inspect` reports, and leaves other connections alone.
- **An SSH port Windows has reserved.** Hyper-V and WinNAT reserve port ranges at boot, and when
  one covers the machine's SSH port, the machine reports itself running while every `podman`
  command gets `connection refused`. When `podman info` does not answer within `-TimeoutSeconds`,
  the task stops and starts the machine once, which lets Podman move SSH to a free port. Each
  `podman info` call is stopped after 20 seconds, so a hung connection counts as no answer.
- **A missing API pipe.** After an unclean shutdown, a socket file left in `%TEMP%\podman` can stop
  the pipe from opening, and compose then fails with `open //./pipe/podman-machine-default: The
  system cannot find the file specified`. The task removes that socket file and restarts the
  machine.

A restart stops every container, so the task skips it while the MCP endpoint (`-ServicePort`, 8765
by default) accepts connections, and logs that it did.

| Result | Meaning |
| --- | --- |
| compose's exit code | The task reached `podman compose up -d`; 0 is a clean run |
| 1 | Podman did not answer even after a restart |
| 2 | The API pipe is still missing after its restart |
| 3 | `podman machine inspect` returned no pipe or socket path |
| 4 | A restart was needed but skipped, because the stack was serving |

The task starts PowerShell through `conhost.exe --headless`, so no console window opens at logon
or on a manual run. conhost reports 0 to Task Scheduler whatever the run returns, so each run ends
by logging `result: <code>`, and `-Status` shows that as `LastResult`. Task Scheduler's own code
appears as `TaskResult`.

```powershell
.\mcp-memory-autostart.ps1 -Install -RunNow   # create the task and run it once
.\mcp-memory-autostart.ps1 -Status            # last run, result code, recent log lines
.\mcp-memory-autostart.ps1 -Uninstall         # remove the task
```

`-StackPath` points the task at a different folder, `-TimeoutSeconds` sets how long it waits for
Podman (120 by default, 10 to 1800), and `-ServicePort` names the endpoint port that marks the stack
as serving.

## Tests

`tests/mcp-memory-autostart.Tests.ps1` covers the task's logic with Pester 5 on Windows. It loads
the script's functions without registering a task or touching the Podman machine, and CI runs it
on every push and pull request:

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

## Troubleshooting

```powershell
podman ps --format '{{.Names}} {{.Status}}'
podman logs mcp-memory --tail 50
.\mcp-memory-autostart.ps1 -Status
```

To upgrade, change the image tag and digest in both services together, run `podman compose up -d`, and
confirm a search through the MCP server returns results.

## License

[MIT](LICENSE). The upstream image is licensed separately by its authors.
