# Analyze newest system crash dump with CDB
# Writes full debug report to C:\OnSystems
# Prints a short summary only

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ===== SETTINGS =====
$ReportRoot  = "C:\OnSystems"
$SymbolCache = "C:\OnSystems\syncrodeploy\Symbols"

# ===== FUNCTIONS =====

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "=================================================="
    Write-Host $Message
    Write-Host "=================================================="
}

function Get-DebuggerPath {
    $Paths = @(
        "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe",
        "C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe",
        "C:\Program Files (x86)\Windows Kits\10\Debuggers\x86\cdb.exe",
        "C:\Program Files\Windows Kits\10\Debuggers\x86\cdb.exe"
    )

    foreach ($Path in $Paths) {
        if (Test-Path -LiteralPath $Path) {
            return $Path
        }
    }

    return $null
}

function Add-DumpCandidate {
    param(
        [string]$Path,
        [System.Collections.Generic.List[object]]$List
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $Item) {
        return
    }

    if ($Item.PSIsContainer) {
        return
    }

    if ($Item.Extension -ieq ".dmp") {
        $List.Add($Item)
    }
}

function Add-DumpCandidatesFromFolder {
    param(
        [string]$FolderPath,
        [System.Collections.Generic.List[object]]$List
    )

    if ([string]::IsNullOrWhiteSpace($FolderPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $FolderPath)) {
        return
    }

    try {
        $Items = Get-ChildItem -LiteralPath $FolderPath -Filter *.dmp -File -ErrorAction SilentlyContinue
        foreach ($Item in $Items) {
            $List.Add($Item)
        }
    }
    catch {
    }
}

function Get-ConfiguredCrashDumpPath {
    $RegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"

    try {
        $DumpFile = (Get-ItemProperty -Path $RegPath -ErrorAction Stop).DumpFile
        if (-not [string]::IsNullOrWhiteSpace($DumpFile)) {
            return [Environment]::ExpandEnvironmentVariables($DumpFile)
        }
    }
    catch {
    }

    return $null
}

function Get-ConfiguredMiniDumpDir {
    $RegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"

    try {
        $MiniDumpDir = (Get-ItemProperty -Path $RegPath -ErrorAction Stop).MinidumpDir
        if (-not [string]::IsNullOrWhiteSpace($MiniDumpDir)) {
            return [Environment]::ExpandEnvironmentVariables($MiniDumpDir)
        }
    }
    catch {
    }

    return $null
}

function Get-SystemDumpCandidates {
    $Candidates = New-Object 'System.Collections.Generic.List[object]'

    $ConfiguredCrashDump = Get-ConfiguredCrashDumpPath
    if ($ConfiguredCrashDump) {
        Add-DumpCandidate -Path $ConfiguredCrashDump -List $Candidates
    }

    $ConfiguredMiniDumpDir = Get-ConfiguredMiniDumpDir
    if ($ConfiguredMiniDumpDir) {
        Add-DumpCandidatesFromFolder -FolderPath $ConfiguredMiniDumpDir -List $Candidates
    }

    Add-DumpCandidate -Path "C:\Windows\MEMORY.DMP" -List $Candidates
    Add-DumpCandidatesFromFolder -FolderPath "C:\Windows\Minidump" -List $Candidates

    if ($Candidates.Count -eq 0) {
        return @()
    }

    $Unique = $Candidates |
        Group-Object -Property FullName |
        ForEach-Object { $_.Group | Select-Object -First 1 }

    return @($Unique | Sort-Object LastWriteTime -Descending)
}

function Get-ReportValue {
    param(
        [string[]]$Lines,
        [string]$Prefix
    )

    $Pattern = "^\s*" + [regex]::Escape($Prefix) + "\s*:"
    $Match = $Lines | Where-Object { $_ -match $Pattern } | Select-Object -First 1

    if ($Match) {
        return $Match.Trim()
    }

    return $null
}

function Get-ProbablyCausedBy {
    param([string[]]$Lines)

    $Match = $Lines | Where-Object { $_ -match 'Probably caused by\s*:' } | Select-Object -First 1
    if ($Match) {
        return $Match.Trim()
    }

    return $null
}

function Get-BugCheckLine {
    param([string[]]$Lines)

    $Match = $Lines | Where-Object { $_ -match '^BugCheck\s' } | Select-Object -First 1
    if ($Match) {
        return $Match.Trim()
    }

    return $null
}

function Get-StackTextTopFrame {
    param([string[]]$Lines)

    $StackIndex = -1

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*STACK_TEXT\s*:') {
            $StackIndex = $i
            break
        }
    }

    if ($StackIndex -lt 0) {
        return $null
    }

    for ($j = $StackIndex + 1; $j -lt $Lines.Count; $j++) {
        $Line = $Lines[$j].Trim()

        if ([string]::IsNullOrWhiteSpace($Line)) {
            continue
        }

        if ($Line -match '^[0-9a-fA-F`]+\s+[0-9a-fA-F`]+\s+') {
            return $Line
        }

        if ($Line -match '^[A-Za-z_].*:') {
            break
        }
    }

    return $null
}

function Test-ReportForSymbolIssues {
    param([string]$ReportPath)

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        return $false
    }

    $Text = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    if ($Text -match 'Kernel symbols are WRONG' -or
        $Text -match 'Symbol Loading Error Summary' -or
        $Text -match 'No export analyze found' -or
        $Text -match 'Failed to download extension ext for command analyze') {
        return $true
    }

    return $false
}

function Show-DebugSummary {
    param([string]$ReportPath)

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        Write-Host "Summary skipped because report file was not found"
        return
    }

    $Lines = @(Get-Content -LiteralPath $ReportPath -ErrorAction SilentlyContinue)
    if (-not $Lines) {
        Write-Host "Summary skipped because report file was empty or unreadable"
        return
    }

    $BugCheck        = Get-BugCheckLine      -Lines $Lines
    $ProbablyCaused  = Get-ProbablyCausedBy  -Lines $Lines
    $ModuleName      = Get-ReportValue       -Lines $Lines -Prefix "MODULE_NAME"
    $ImageName       = Get-ReportValue       -Lines $Lines -Prefix "IMAGE_NAME"
    $FailureBucketId = Get-ReportValue       -Lines $Lines -Prefix "FAILURE_BUCKET_ID"
    $ProcessName     = Get-ReportValue       -Lines $Lines -Prefix "PROCESS_NAME"
    $TopFrame        = Get-StackTextTopFrame -Lines $Lines

    Write-Section "Debug summary"

    if (Test-ReportForSymbolIssues -ReportPath $ReportPath) {
        Write-Host "Analysis confidence low due to symbol loading issues"
    } else {
        Write-Host "Analysis confidence normal"
    }

    if ($BugCheck)        { Write-Host $BugCheck }
    if ($ProbablyCaused)  { Write-Host $ProbablyCaused }
    if ($ModuleName)      { Write-Host $ModuleName }
    if ($ImageName)       { Write-Host $ImageName }
    if ($FailureBucketId) { Write-Host $FailureBucketId }
    if ($ProcessName)     { Write-Host $ProcessName }

    if ($TopFrame) {
        Write-Host "STACK_TEXT top frame"
        Write-Host $TopFrame
    }
}

# ===== SCRIPT START =====

try {
    if (-not (Test-Path -LiteralPath $ReportRoot)) {
        New-Item -Path $ReportRoot -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $SymbolCache)) {
        New-Item -Path $SymbolCache -ItemType Directory -Force | Out-Null
    }

    $CdbPath = Get-DebuggerPath
    if (-not $CdbPath) {
        throw "cdb.exe was not found. Run Install-DebuggingTools.ps1 first."
    }

    $CdbVersion = (Get-Item -LiteralPath $CdbPath).VersionInfo.FileVersion

    $DumpCandidates = @(Get-SystemDumpCandidates)
    if ($DumpCandidates.Count -eq 0) {
        throw "No system dump files were found"
    }

    $NewestDump = $DumpCandidates | Select-Object -First 1

    $DumpBaseName = [System.IO.Path]::GetFileNameWithoutExtension($NewestDump.Name)
    $TimeStamp    = Get-Date -Format "yyyyMMdd_HHmmss"
    $ReportName   = $DumpBaseName + "_debugreport_" + $TimeStamp + ".txt"
    $ReportPath   = Join-Path -Path $ReportRoot -ChildPath $ReportName

    # Derive ext.dll from the resolved CDB path to avoid x86/x64 mismatch
    $DebuggerDir = Split-Path -Parent $CdbPath
    $ExtDll      = Join-Path $DebuggerDir "winext\ext.dll"
    $SymbolPath  = "srv*" + $SymbolCache + "*https://msdl.microsoft.com/download/symbols"

    # Load ext.dll explicitly to bypass extension gallery download failures
    # .reload without /f avoids hanging on large dumps
    $Commands = ".load `"$ExtDll`"; .reload; !analyze -v; kv; q"

    Write-Section "Running debugger"
    Write-Host "Debugger         $CdbPath"
    Write-Host "Debugger version $CdbVersion"
    Write-Host "Dump file        $($NewestDump.FullName)"
    Write-Host "Dump date        $($NewestDump.LastWriteTime)"
    Write-Host "Report file      $ReportPath"

    # Run CDB with a 5-minute timeout to prevent indefinite hangs
    $ProcArgs = @(
        "-z", "`"$($NewestDump.FullName)`"
        "-y", "`"$SymbolPath`"
        "-logo", "`"$ReportPath`"
        "-c", "`"$Commands`""
    )

    $Proc     = Start-Process -FilePath $CdbPath -ArgumentList $ProcArgs -NoNewWindow -PassThru
    $Finished = $Proc.WaitForExit(300000)

    if (-not $Finished) {
        $Proc.Kill()
        throw "CDB did not complete within the 5 minute timeout"
    }

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "Debug report was not created"
    }

    Show-DebugSummary -ReportPath $ReportPath

    Write-Section "Completed"
    Write-Host "Report file $ReportPath"
}
catch {
    Write-Section "Debug run failed"
    Write-Host $_.Exception.Message
    exit 1
}