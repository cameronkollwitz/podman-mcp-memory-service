#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# These tests load functions from mcp-memory-autostart.ps1 by parsing it, so
# nothing is registered with Task Scheduler and no Podman machine is touched.
# The run script's functions are tested by generating the script with
# Get-RunScriptText and loading each function from that text. They need Windows:
# the stubs are .cmd files, and the connections-file lock is a Windows
# byte-range lock.

BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'mcp-memory-autostart.ps1'
    $outer = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    function Get-FunctionText {
        param($Ast, [string]$Name)
        $found = $Ast.FindAll({
                param($n)
                $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
            }, $true)
        if (@($found).Count -ne 1) { throw "Expected one function named $Name, found $(@($found).Count)." }
        $found[0].Extent.Text
    }

    . ([scriptblock]::Create((Get-FunctionText $outer 'Get-RunScriptText')))
    . ([scriptblock]::Create((Get-FunctionText $outer 'Get-LastRunResult')))

    # Generates the run script and returns its syntax tree and text.
    function Get-RunScript {
        param([string]$Podman = 'podman.exe', [int]$TimeoutSeconds = 120, [int]$ServicePort = 8765)
        $text = Get-RunScriptText -Podman $Podman -LogPath (Join-Path $TestDrive 'run.log') `
            -StackPath $TestDrive -TimeoutSeconds $TimeoutSeconds -ServicePort $ServicePort
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        [pscustomobject]@{ Text = $text; Ast = $ast; Errors = $errors }
    }

    # Returns the text of the named run-script functions, for dot-sourcing in a test.
    function Get-RunFunction {
        param([string[]]$Name, [int]$ServicePort = 8765, [string]$Podman = 'podman.exe')
        $run = Get-RunScript -ServicePort $ServicePort -Podman $Podman
        ($Name | ForEach-Object { Get-FunctionText $run.Ast $_ }) -join "`n"
    }

    $shellPath = (Get-Process -Id $PID).Path
}

Describe 'Get-RunScriptText' {
    It 'generates a script that parses without errors' {
        (Get-RunScript).Errors | Should -BeNullOrEmpty
    }

    It 'embeds the timeout and the service port' {
        $run = Get-RunScript -TimeoutSeconds 137 -ServicePort 18765
        $run.Text | Should -Match 'AddSeconds\(137\)'
        $run.Text | Should -Match "ConnectAsync\('127\.0\.0\.1', 18765\)"
    }

    It 'exits only through Exit-Run, so every run logs its result' {
        $run = Get-RunScript
        $exits = $run.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true)
        @($exits).Count | Should -BeGreaterThan 0
        foreach ($exit in $exits) {
            $parent = $exit.Parent
            while ($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
            $parent.Name | Should -Be 'Exit-Run' -Because "line $($exit.Extent.StartLineNumber) exits without logging a result"
        }
    }

    It 'restarts the machine only through Restart-Machine' {
        $run = Get-RunScript
        $stops = [regex]::Matches($run.Text, 'machine stop')
        $stops.Count | Should -Be 1
        (Get-FunctionText $run.Ast 'Restart-Machine') | Should -Match 'machine stop'
    }
}

Describe 'Sync-ConnectionPort' {
    BeforeEach {
        $appData = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $appData 'containers') | Out-Null
        $file = Join-Path $appData 'containers\podman-connections.json'
        $sample = '{"Connection":{"Default":"podman-machine-default","Connections":{' +
            '"podman-machine-default":{"URI":"ssh://user@127.0.0.1:51057/run/user/1000/podman/podman.sock","Identity":"C:\\Users\\Jos' + [char]0xE9 + '\\key","IsMachine":true},' +
            '"podman-machine-default-root":{"URI":"ssh://root@127.0.0.1:51057/run/podman/podman.sock","Identity":"x","IsMachine":true},' +
            '"other":{"URI":"ssh://user@127.0.0.1:50123/run/user/1000/podman/podman.sock","Identity":"x","IsMachine":true}}},"Farm":{}}'
        [IO.File]::WriteAllText($file, $sample, (New-Object Text.UTF8Encoding $false))
        $savedAppData = $env:APPDATA
        $env:APPDATA = $appData
        $log = Join-Path $appData 'run.log'
        function Log($m) { "$m" | Add-Content -LiteralPath $log -Encoding utf8 }
        . ([scriptblock]::Create((Get-RunFunction 'Sync-ConnectionPort')))
    }

    AfterEach {
        $env:APPDATA = $savedAppData
    }

    It 'rewrites only the machine connections, as UTF-8 without a BOM' {
        $podman = { 'podman-machine-default|49803' }
        Sync-ConnectionPort
        $out = [IO.File]::ReadAllText($file)
        $out | Should -Match 'user@127\.0\.0\.1:49803/'
        $out | Should -Match 'root@127\.0\.0\.1:49803/'
        $out | Should -Match 'user@127\.0\.0\.1:50123/'
        $out.Contains('Jos' + [char]0xE9) | Should -BeTrue
        [IO.File]::ReadAllBytes($file)[0] | Should -Not -Be 0xEF
        Test-Path "$file.autostart.tmp" | Should -BeFalse
    }

    It 'leaves the file alone when the port is not a positive number' -TestCases @(
        @{ Reported = 'podman-machine-default|<no value>' }
        @{ Reported = 'podman-machine-default|0' }
        @{ Reported = '|49803' }
    ) {
        param($Reported)
        $podman = [scriptblock]::Create("'$Reported'")
        $before = [IO.File]::ReadAllText($file)
        Sync-ConnectionPort
        [IO.File]::ReadAllText($file) | Should -Be $before
    }

    It 'gives up and logs when another process holds the lock' {
        $podman = { 'podman-machine-default|49803' }
        $held = [IO.File]::Open("$file.lock", 'OpenOrCreate', 'ReadWrite', 'ReadWrite')
        try {
            $held.Lock(0, 1)
            $before = [IO.File]::ReadAllText($file)
            Sync-ConnectionPort
            [IO.File]::ReadAllText($file) | Should -Be $before
            Get-Content -LiteralPath $log | Should -Match 'Could not lock'
        }
        finally {
            $held.Close()
        }
    }
}

Describe 'Test-PodmanAnswers' {
    BeforeAll {
        Set-Content -LiteralPath (Join-Path $TestDrive 'ok.cmd') '@exit /b 0' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $TestDrive 'fail.cmd') '@exit /b 1' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $TestDrive 'hang.cmd') '@ping -n 26 127.0.0.1 >nul' -Encoding ascii
    }

    BeforeEach {
        $log = Join-Path $TestDrive "$([guid]::NewGuid()).log"
        function Log($m) { "$m" | Add-Content -LiteralPath $log }
    }

    It 'returns <Expected> for <Stub>' -TestCases @(
        @{ Stub = 'ok.cmd'; Expected = $true }
        @{ Stub = 'fail.cmd'; Expected = $false }
    ) {
        param($Stub, $Expected)
        $podman = Join-Path $TestDrive $Stub
        . ([scriptblock]::Create((Get-RunFunction 'Test-PodmanAnswers' -Podman $podman)))
        Test-PodmanAnswers | Should -Be $Expected
    }

    It 'stops a call that hangs and reports no answer' {
        $podman = Join-Path $TestDrive 'hang.cmd'
        . ([scriptblock]::Create((Get-RunFunction 'Test-PodmanAnswers' -Podman $podman)))
        $elapsed = Measure-Command { $answered = Test-PodmanAnswers }
        $answered | Should -BeFalse
        $elapsed.TotalSeconds | Should -BeLessThan 24
        Get-Content -LiteralPath $log | Should -Match 'did not return within 20 seconds'
    }
}

Describe 'Test-StackServing and Skip-IfServing' {
    BeforeEach {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
    }

    AfterEach {
        $listener.Stop()
    }

    It 'sees an open port as serving and a closed one as not' {
        . ([scriptblock]::Create((Get-RunFunction 'Test-StackServing' -ServicePort $port)))
        Test-StackServing | Should -BeTrue
        $listener.Stop()
        Test-StackServing | Should -BeFalse
    }

    It 'exits with 4 and logs the result while the port is serving' {
        $log = Join-Path $TestDrive "$([guid]::NewGuid()).log"
        $child = Join-Path $TestDrive "$([guid]::NewGuid()).ps1"
        $functions = Get-RunFunction 'Exit-Run', 'Test-StackServing', 'Skip-IfServing' -ServicePort $port
        Set-Content -LiteralPath $child -Encoding utf8 -Value @(
            "function Log(`$m) { `$m | Add-Content -LiteralPath '$log' }"
            $functions
            "Skip-IfServing 'test'"
            "exit 0"
        )
        & $shellPath -NoProfile -NonInteractive -File $child
        $LASTEXITCODE | Should -Be 4
        Get-Content -LiteralPath $log | Should -Contain 'result: 4'
    }
}

Describe 'Get-LastRunResult' {
    It 'returns <Expected> for <Case>' -TestCases @(
        @{ Case = 'a clean last run'; Lines = @('t  --- logon start ---', 't  result: 1', 't  --- logon start ---', 't  result: 0'); Expected = '0' }
        @{ Case = 'a failed last run'; Lines = @('t  --- logon start ---', 't  result: 0', 't  --- logon start ---', 't  result: 4'); Expected = '4' }
        @{ Case = 'a run that never logged a result'; Lines = @('t  --- logon start ---', 't  result: 0', 't  --- logon start ---', 't  waiting'); Expected = 'none (running, or stopped before it finished)' }
    ) {
        param($Case, $Lines, $Expected)
        $path = Join-Path $TestDrive "$([guid]::NewGuid()).log"
        Set-Content -LiteralPath $path -Value $Lines
        Get-LastRunResult -Path $path | Should -Be $Expected
    }

    It 'reports a missing log' {
        Get-LastRunResult -Path (Join-Path $TestDrive 'missing.log') | Should -Be 'no log'
    }
}

Describe '-WhatIf' {
    It 'registers nothing' {
        $bin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin 'podman.cmd') '@exit /b 0' -Encoding ascii
        $name = "mcp-memory-whatif-$([guid]::NewGuid())"
        $stack = Split-Path $scriptPath -Parent
        $env:Path = "$bin;$env:Path"
        try {
            & $scriptPath -Install -StackPath $stack -TaskName $name -WhatIf 6>$null
        }
        finally {
            $env:Path = $env:Path.Substring($bin.Length + 1)
        }
        Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
