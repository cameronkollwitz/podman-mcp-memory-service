# podman-mcp-memory-service

A Podman compose stack that runs `doobidoo/mcp-memory-service` 11.14.0 on this Windows machine.
It is the memory server every Claude Code session on the machine uses, this repository's included,
so a change here can take memory away from all of them at once.

## What runs

`compose.yaml` defines two containers from the same image, pinned by tag in both services.

| Container | Port | Reads | Serves |
| --- | --- | --- | --- |
| `mcp-memory` | 8765 | `core.env` | The MCP endpoint. Claude Code reaches it as the user-scoped `memory` server at `http://127.0.0.1:8765/mcp`. |
| `mcp-memory-ui` | 8000 | `ui.env` | `memory server --http`, the dashboard and REST API. |

Both mount the volumes `mcp-memory` (the SQLite database) and `mcp-models` (the model cache), and
each has its own backups volume. All four volumes are `external`, so compose never creates them.
The storage backend is `hybrid`: SQLite in the
volume, synchronized to Cloudflare D1 and Vectorize.

Podman has no daemon, so `restart: always` does not bring the stack back after a reboot.
`mcp-memory-autostart.ps1` installs a logon task that does, and `-Status` reports its last run and
the tail of its log.

## Use the memory server

The operator's global instructions set the procedure: load the standing memories before the first
reply, search for task context, and store decisions, conventions, gotchas and preferences. This
repository's tag is `podman-mcp-memory-service`, and every memory stored here carries it beside a
type tag. A memory recording how the operator wants work done also carries `standing`.

**Search by tag and exact phrase before concluding nothing was recorded.** On 2026-09-23 a
semantic search returned another repository's record first, so
pair `mode: exact` with `tags: ["podman-mcp-memory-service"]`, and use a semantic query only to
widen the search after that.

**Memory goes to the server and never to a file.** The harness offers a file-based memory directory
and `MEMORY.md`; neither takes a write in this repository.

**When the server does not answer, every message ends with the heading
`# MEMORY SERVER IS OFFLINE` until it answers again.** Here the cause is almost always this stack,
so check it before anything else:

```powershell
podman ps --format '{{.Names}} {{.Status}}'
.\mcp-memory-autostart.ps1 -Status
podman compose up -d
```

**Stopping or recreating `mcp-memory` removes the session's own memory tools until it is back.**
Store anything worth keeping before a `down`, an image bump or an env change, and expect the tools
to fail until the container is up again. A database or volume change that could lose memories is
confirmed with the operator first, with a backup taken.

## Secrets

`core.env` and `ui.env` hold the Cloudflare API token and the MCP API key, and `*.env` in
`.gitignore` keeps them out of the tree. `core.env.example` and `ui.env.example` are the tracked
templates, with every secret as a `<PLACEHOLDER>`. A variable added to a live file is added to its
template in the same change. The `Authorization` header of the `memory` entry in
`~/.claude.json` carries the same API key. Never print any of these values, never paste them into
a memory, and read a live env file only for its variable names.

## Verify before asserting

The image is versioned by someone else, so what is remembered about its variables, commands or
storage was true of some version. Read the version that is running: the image tag in
`compose.yaml`, `podman exec mcp-memory memory --help`, or the upstream README at the matching tag.
An image bump changes the tag in both services together, and the stack is brought up and checked
with a `memory_search` call afterwards.

## Git

`main` is the only branch, and it pushes to `origin` on GitHub. Commit and push when the operator
asks. **No agent authorship**: commit messages and pull request bodies carry no
`Co-Authored-By: Claude` or generated-with line, matching the operator's other
repositories. `.claude/settings.json` sets both attribution strings empty, which stops the harness
asking for them.

## Editor

Open the repository root, or `.vscode/development.code-workspace`, whose only folder is `..`.
Project settings are read from the directory a session starts in. The workspace file and
`.vscode/settings.json` hold the same settings on purpose, and the comment in the workspace file
explains why; an edit to one is made to both.
