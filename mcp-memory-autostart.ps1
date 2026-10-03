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

Log '--- logon start ---'
& `$podman machine start *>&1 | ForEach-Object { Log `$_ }

`$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while (`$true) {
    & `$podman info *> `$null
    if (`$LASTEXITCODE -eq 0) { break }
    if ((Get-Date) -gt `$deadline) { Log 'Podman did not respond in time; giving up.'; exit 1 }
    Start-Sleep -Seconds 3
}

Set-Location -LiteralPath '$(& $esc $StackPath)'
& `$podman compose up -d *>&1 | ForEach-Object { Log `$_ }
Log "compose exit code: `$LASTEXITCODE"
"@
        # Encode the script so no path or quote can break the task's command line.
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runScript))

        $action = New-ScheduledTaskAction -Execute $shell `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

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
