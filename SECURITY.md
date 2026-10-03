# Security policy

## Scope

This repository holds a compose file, env templates and a PowerShell logon script. A report about
them belongs here: for example, a template that leaks a secret, a compose setting that exposes a
service, or a script that runs something it should not.

The server itself is [doobidoo/mcp-memory-service](https://github.com/doobidoo/mcp-memory-service).
A vulnerability in its code or its image goes to that project.

## Supported versions

Only the current `main` branch is supported, with the image tag pinned in `compose.yaml`. A fix is
made on `main` and is not backported.

## Reporting a vulnerability

Report it privately through
[GitHub's private vulnerability reporting](https://github.com/cameronkollwitz/podman-mcp-memory-service/security/advisories/new),
and do not open a public issue. Include the file and setting involved and what an attacker could
do with it.

This is a personal project maintained in spare time, so replies come when time allows. A confirmed
report is fixed on `main` and credited in the advisory unless you ask otherwise.

## Running the stack safely

- Keep `core.env` and `ui.env` out of version control. `.gitignore` already excludes `*.env`.
- Set a long random `MCP_API_KEY`, and give the Cloudflare API token access to only the D1
  database and Vectorize index this stack uses.
- `compose.yaml` publishes ports 8765 and 8000 on `127.0.0.1` only. Keep that prefix unless
  another machine needs to reach the server; without it, Podman on Linux publishes the ports on
  every interface. The `0.0.0.0` host settings in the env files are the address inside the
  container and stay as they are.
