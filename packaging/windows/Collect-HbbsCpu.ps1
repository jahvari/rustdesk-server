# Run in ordinary Windows PowerShell 5.1; elevation is not required.
# Uses fresh test data and loopback listeners. Stops only the process it starts.
# Use a disposable test Windows profile/VM: hbbs's update checker also accesses
# the account's RustDesk client configuration through Windows known folders.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BinaryPath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidateRange(10, 3600)][int]$DurationSeconds = 720,
    [ValidateRange(1, 30)][int]$SampleSeconds = 2,
    [ValidateRange(1024, 65533)][int]$Port = 35516
)
$ErrorActionPreference = 'Stop'
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Choose a new output directory for each run.' }
$data = Join-Path $output 'test-data'
$null = New-Item -ItemType Directory -Path $data -Force
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $binary
$start.Arguments = "--bind 127.0.0.1 --port $Port -r 127.0.0.1:$($Port + 1)"
$start.WorkingDirectory = $data
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.EnvironmentVariables['APPDATA'] = Join-Path $data 'Roaming'
$start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $data 'Local'
$start.EnvironmentVariables['DB_URL'] = 'db_v2.sqlite3'
$start.EnvironmentVariables['KEY'] = '-'
$start.EnvironmentVariables['DB-URL'] = 'db_v2.sqlite3'
$start.EnvironmentVariables['TEST_HBBS'] = ''
$start.EnvironmentVariables['TEST-HBBS'] = ''
$start.EnvironmentVariables['RUST_LOG'] = 'info'
$process = New-Object Diagnostics.Process
$process.StartInfo = $start
$samples = New-Object 'System.Collections.Generic.List[object]'
$threads = New-Object 'System.Collections.Generic.List[object]'
$clock = [Diagnostics.Stopwatch]::StartNew()
$started = $false
try {
    $started = $process.Start()
    if (!$started) { throw 'Could not start hbbs.' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
    $process.Refresh()
    if ($process.PriorityClass -ne [Diagnostics.ProcessPriorityClass]::Normal) {
        throw 'The test requires Normal process priority; inherited lower priority could mask issue #186.'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    [ordered]@{
        Binary = $binary
        BinarySHA256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        OS = $os.Caption
        OSVersion = $os.Version
        LogicalProcessors = [Environment]::ProcessorCount
        ProcessId = $process.Id
        PriorityClass = [string]$process.PriorityClass
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        Arguments = $start.Arguments
        DurationSeconds = $DurationSeconds
        SelfTest = 'enabled'
        LogLevel = 'info'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding UTF8
    $previousWall = $clock.Elapsed.TotalSeconds
    $previousCpu = $process.TotalProcessorTime.TotalSeconds
    while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
        Start-Sleep -Seconds $SampleSeconds
        if ($process.HasExited) { throw "hbbs exited early with code $($process.ExitCode). See captured logs." }
        $process.Refresh()
        $wall = $clock.Elapsed.TotalSeconds
        $cpu = $process.TotalProcessorTime.TotalSeconds
        $corePercent = 100 * ($cpu - $previousCpu) / ($wall - $previousWall)
        $samples.Add([pscustomobject]@{
            ElapsedSeconds = [Math]::Round($wall, 3)
            CpuSeconds = $cpu
            CpuPercentOneCore = [Math]::Round($corePercent, 3)
            CpuPercentMachine = [Math]::Round($corePercent / [Environment]::ProcessorCount, 3)
            WorkingSetBytes = $process.WorkingSet64
            ThreadCount = $process.Threads.Count
            Handles = $process.HandleCount
        })
        foreach ($thread in $process.Threads) {
            try {
                $threads.Add([pscustomobject]@{
                    ElapsedSeconds = [Math]::Round($wall, 3)
                    ThreadId = $thread.Id
                    CpuSeconds = $thread.TotalProcessorTime.TotalSeconds
                    BasePriority = $thread.BasePriority
                    CurrentPriority = $thread.CurrentPriority
                    State = [string]$thread.ThreadState
                })
            } catch { } # A thread may exit between enumeration and inspection.
        }
        $previousCpu = $cpu
        $previousWall = $wall
    }
} finally {
    if ($started) {
        if (!$process.HasExited) { $process.Kill() }
        $process.WaitForExit()
        $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $output 'stdout.log') -Encoding UTF8
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $output 'stderr.log') -Encoding UTF8
    }
    $samples | Export-Csv -LiteralPath (Join-Path $output 'cpu.csv') -NoTypeInformation
    $threads | Export-Csv -LiteralPath (Join-Path $output 'threads.csv') -NoTypeInformation
    $process.Dispose()
}
Write-Output "Captured $($samples.Count) samples in $output"
