<#
.SYNOPSIS
    Installs or removes a Windows logon task that starts the Podman machine
    and brings up the mcp-memory compose stack.

.DESCRIPTION
    Podman has no daemon, so containers with "restart: always" are not started
    again after a Windows reboot. This task runs at logon, starts the Podman
    machine if needed, waits until Podman responds, then runs
    "podman compose up -d" in the stack folder. Output from each run is
    appended to a log file.

    Before waiting, the task rewrites the port in podman-connections.json when
    it differs from the machine's SSH port, which drifts when Podman was run
    from an MSIX-packaged app such as the Claude desktop app.
    If Podman does not answer within the timeout, the task stops and starts the
    machine once, which lets Podman move its SSH port when Windows has reserved
    the old one. If the machine's API pipe is missing, the task removes the
    machine's API socket file and restarts the machine before running compose.
    The task's result code is compose's exit code, 1 when Podman did not respond
    after a restart, or 2 when the pipe is still missing after the restart.

.EXAMPLE
    .\mcp-memory-autostart.ps1 -Install -StackPath 'D:\stacks\mcp-memory' -RunNow

    .\mcp-memory-autostart.ps1 -Install -RunNow   # create the task and run it once
    .\mcp-memory-autostart.ps1 -Status            # last run, result code, recent log lines
    .\mcp-memory-autostart.ps1 -Uninstall         # remove the task
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory)]
    [switch]$Install,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    # Folder containing compose.yaml. Defaults to the folder this script is in.
    [Parameter(ParameterSetName = 'Install')]
    [string]$StackPath = $PSScriptRoot,

    # Run the task once right after installing it.
    [Parameter(ParameterSetName = 'Install')]
    [switch]$RunNow,

    # Seconds to wait for the Podman machine to respond before giving up.
    [Parameter(ParameterSetName = 'Install')]
    [int]$TimeoutSeconds = 120,

    [string]$TaskName = 'Start mcp-memory'
)

$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $env:LOCALAPPDATA 'mcp-memory-autostart.log'

function Get-ExistingTask {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

switch ($PSCmdlet.ParameterSetName) {

    'Install' {
        $StackPath = (Resolve-Path $StackPath).Path
        if (-not (Test-Path (Join-Path $StackPath 'compose.yaml')) -and
            -not (Test-Path (Join-Path $StackPath 'docker-compose.yml'))) {
            throw "No compose.yaml found in '$StackPath'. Pass -StackPath with the stack folder."
        }

        $podman = (Get-Command podman -ErrorAction SilentlyContinue).Source
        if (-not $podman) { throw 'podman.exe not found on PATH.' }

        $shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if (-not $shell) { $shell = (Get-Command powershell).Source }

        # The script the task runs. Paths are embedded as single-quoted literals.
        $esc = { param($s) $s -replace "'", "''" }
        $runScript = @"
`$ErrorActionPreference = 'Continue'
`$podman = '$(& $esc $podman)'
`$log = '$(& $esc $LogPath)'
function Log(`$m) { "`$(Get-Date -Format s)  `$m" | Add-Content -Path `$log }

function Wait-Podman {
    `$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (`$true) {
        & `$podman info *> `$null
        if (`$LASTEXITCODE -eq 0) { return `$true }
        if ((Get-Date) -gt `$deadline) { return `$false }
        Start-Sleep -Seconds 3
    }
}

# The machine file keeps the SSH port and podman-connections.json keeps a copy
# in each connection URI. Podman run from an MSIX-packaged app (the Claude
# desktop app) writes the connections file into the package's private copy of
# AppData, so a port change made there never reaches the real file, and every
# process outside the package keeps dialing the old port.
# Only the machine's own two connections are rewritten, so other machines and
# hand-added connections keep their ports. The file is read and written as
# UTF-8 without a BOM, which is what Podman writes; Windows PowerShell 5.1
# cmdlets would default to ANSI.
function Sync-ConnectionPort {
    `$name, `$port = ((& `$podman machine inspect --format '{{.Name}}|{{.SSHConfig.Port}}' 2>`$null) |
        Select-Object -First 1) -split '\|'
    `$file = Join-Path `$env:APPDATA 'containers\podman-connections.json'
    if (-not `$name -or `$port -notmatch '^\d+$' -or [int]`$port -le 0) { return }
    if (-not (Test-Path -LiteralPath `$file)) { return }
    `$json = [IO.File]::ReadAllText(`$file)
    try { `$conns = (`$json | ConvertFrom-Json).Connection.Connections } catch { return }
    `$fixed = `$json
    foreach (`$n in @(`$name, "`$name-root")) {
        `$c = `$conns.`$n
        if (-not `$c -or -not `$c.IsMachine) { continue }
        `$uri = `$c.URI -replace '^(ssh://[^@/]+@127\.0\.0\.1:)\d+/', ('`${1}' + `$port + '/')
        if (`$uri -ne `$c.URI) { `$fixed = `$fixed.Replace('"' + `$c.URI + '"', '"' + `$uri + '"') }
    }
    if (`$fixed -ne `$json) {
        Log "Connection URIs for `$name did not match machine SSH port `$port; rewriting `$file."
        [IO.File]::WriteAllText(`$file, `$fixed, (New-Object Text.UTF8Encoding `$false))
    }
}

function Restart-Machine {
    & `$podman machine stop *>&1 | ForEach-Object { Log `$_ }
    & `$podman machine start *>&1 | ForEach-Object { Log `$_ }
}

# podman info answers over SSH, so it succeeds while the named pipe that
# compose needs is missing. win-sshproxy creates the pipe and exits when a
# socket file left by an unclean shutdown blocks its bind.
function Test-Pipe {
    `$deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath `$pipe)) {
        if ((Get-Date) -gt `$deadline) { return `$false }
        Start-Sleep -Seconds 1
    }
    `$true
}

Log '--- logon start ---'
& `$podman machine start *>&1 | ForEach-Object { Log `$_ }

# machine list reports the VM as running while Windows refuses its SSH port,
# which happens when the port falls inside a range Hyper-V or WinNAT reserved
# at boot. machine start skips a running VM, so only a stop and start lets
# Podman detect the conflict and move SSH to a free port.
Sync-ConnectionPort
if (-not (Wait-Podman)) {
    Log 'Podman did not answer over SSH in time; restarting the machine.'
    Restart-Machine
    Sync-ConnectionPort
    if (-not (Wait-Podman)) { Log 'Podman did not answer after the restart; giving up.'; exit 1 }
}

`$pipe, `$sock = (& `$podman machine inspect --format '{{.ConnectionInfo.PodmanPipe.Path}}|{{.ConnectionInfo.PodmanSocket.Path}}') -split '\|'
if (-not (Test-Pipe)) {
    Log "API pipe `$pipe is missing; removing `$sock and restarting the machine."
    & `$podman machine stop *>&1 | ForEach-Object { Log `$_ }
    Remove-Item -LiteralPath `$sock -Force -ErrorAction SilentlyContinue
    & `$podman machine start *>&1 | ForEach-Object { Log `$_ }
    if (-not (Wait-Podman)) { Log 'Podman did not answer after the restart; giving up.'; exit 1 }
    if (-not (Test-Pipe)) { Log "API pipe `$pipe is still missing; giving up."; exit 2 }
}

Set-Location -LiteralPath '$(& $esc $StackPath)'
& `$podman compose up -d *>&1 | ForEach-Object { Log `$_ }
`$code = `$LASTEXITCODE
Log "compose exit code: `$code"
exit `$code
"@
        # Encode the script so no path or quote can break the task's command line.
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runScript))

        $action = New-ScheduledTaskAction -Execute $shell `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        # A run can wait for Podman three times (first start, SSH restart, pipe
        # restart) and restart the machine twice before compose runs. The limit
        # covers the three waits plus five minutes for restarts and compose, so
        # Task Scheduler does not stop the run before it logs a result.
        $limit = New-TimeSpan -Seconds ([Math]::Max(600, 3 * $TimeoutSeconds + 300))
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit $limit

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings `
            -Description "Starts the Podman machine and the compose stack in $StackPath at logon." `
            -Force | Out-Null

        Write-Host "Installed task '$TaskName' for $StackPath"
        Write-Host "Log file: $LogPath"

        if ($RunNow) {
            Start-ScheduledTask -TaskName $TaskName
            Write-Host 'Task started. Check the log or run: podman ps'
        }
    }

    'Uninstall' {
        if (Get-ExistingTask) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Removed task '$TaskName'."
        }
        else {
            Write-Host "Task '$TaskName' is not installed."
        }
        Write-Host "The log file was left in place: $LogPath"
    }

    'Status' {
        $task = Get-ExistingTask
        if (-not $task) { Write-Host "Task '$TaskName' is not installed."; return }
        $info = $task | Get-ScheduledTaskInfo
        [pscustomobject]@{
            Task        = $TaskName
            State       = $task.State
            LastRun     = $info.LastRunTime
            LastResult  = '0x{0:X}' -f $info.LastTaskResult
            Description = $task.Description
            Log         = $LogPath
        } | Format-List
        if (Test-Path $LogPath) {
            Write-Host 'Last log lines:'
            Get-Content $LogPath -Tail 10
        }
    }
}
