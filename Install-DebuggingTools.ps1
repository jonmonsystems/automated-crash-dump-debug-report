# Install or update Debugging Tools for Windows to the latest SDK-delivered version
# Downloads current Windows SDK installer and installs only the debugger tools
# Designed for Syncro RMM deployment - runs as SYSTEM
# Separate from crash dump analysis script - run this first, on demand

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ===== SETTINGS =====
# Stable FWLink from Microsoft Windows SDK downloads page - resolves to current SDK installer
$SdkUrl         = "https://go.microsoft.com/fwlink/?linkid=2349110"
$InstallRoot    = "C:\OnSystems\syncrodeploy\windebug"
$SdkInstaller   = Join-Path $InstallRoot "winsdksetup.exe"
$MinimumVersion = [version]"10.0.26100.0"

# ===== FUNCTIONS =====

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "=================================================="
    Write-Host $Text
    Write-Host "=================================================="
}

function Get-DebuggerCandidates {
    $Paths = @(
        "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe",
        "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\windbg.exe",
        "C:\Program Files (x86)\Windows Kits\10\Debuggers\x86\cdb.exe",
        "C:\Program Files (x86)\Windows Kits\10\Debuggers\x86\windbg.exe",
        "C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe",
        "C:\Program Files\Windows Kits\10\Debuggers\x64\windbg.exe",
        "C:\Program Files\Windows Kits\10\Debuggers\x86\cdb.exe",
        "C:\Program Files\Windows Kits\10\Debuggers\x86\windbg.exe"
    )

    $Found = foreach ($Path in $Paths) {
        if (Test-Path -LiteralPath $Path) {
            $Item = Get-Item -LiteralPath $Path
            [pscustomobject]@{
                Path        = $Item.FullName
                Name        = $Item.Name
                VersionText = $Item.VersionInfo.FileVersion
                Version     = try { [version]($Item.VersionInfo.FileVersion -replace ' .*', '') } catch { [version]"0.0.0.0" }
            }
        }
    }

    return @($Found)
}

function Get-HighestDebuggerVersion {
    $Candidates = @(Get-DebuggerCandidates)
    if ($Candidates.Count -eq 0) {
        return $null
    }
    return $Candidates | Sort-Object Version -Descending | Select-Object -First 1
}

function Test-DebuggerVersionSufficient {
    param([version]$MinimumRequiredVersion)
    $Highest = Get-HighestDebuggerVersion
    if ($null -eq $Highest) {
        return $false
    }
    return ($Highest.Version -ge $MinimumRequiredVersion)
}

# ===== SCRIPT START =====

try {
    Write-Section "Checking current debugger version"

    $Existing = @(Get-DebuggerCandidates)

    if ($Existing.Count -gt 0) {
        Write-Host "Existing debugger files found"
        $Existing | Sort-Object Version -Descending | ForEach-Object {
            Write-Host "$($_.Name)  $($_.VersionText)  $($_.Path)"
        }
    } else {
        Write-Host "No existing debugger files found"
    }

    if (Test-DebuggerVersionSufficient -MinimumRequiredVersion $MinimumVersion) {
        $Highest = Get-HighestDebuggerVersion
        Write-Host "Debugger version already meets minimum requirement"
        Write-Host "Installed version $($Highest.VersionText)"
        Write-Host "No install needed"
        exit 0
    }

    Write-Section "Preparing folder"

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        Write-Host "Creating folder $InstallRoot"
        New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
    } else {
        Write-Host "Folder already exists $InstallRoot"
    }

    Write-Section "Downloading current Windows SDK installer"

    Write-Host "Source $SdkUrl"
    Write-Host "Destination $SdkInstaller"

    Invoke-WebRequest -Uri $SdkUrl -OutFile $SdkInstaller -UseBasicParsing

    if (-not (Test-Path -LiteralPath $SdkInstaller)) {
        throw "winsdksetup.exe was not downloaded"
    }

    $Size = (Get-Item -LiteralPath $SdkInstaller).Length / 1MB
    Write-Host ("Downloaded installer size {0:N2} MB" -f $Size)

    Write-Section "Installing Windows Desktop Debuggers"

    $Arguments = @(
        "/features", "OptionId.WindowsDesktopDebuggers",
        "/quiet",
        "/norestart"
    )

    Write-Host "Running installer"
    Write-Host "$SdkInstaller $($Arguments -join ' ')"

    $Proc = Start-Process `
        -FilePath $SdkInstaller `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    Write-Host "Installer exit code $($Proc.ExitCode)"

    if ($Proc.ExitCode -ne 0) {
        throw "SDK installer failed with exit code $($Proc.ExitCode)"
    }

    Write-Section "Validating debugger version after install"

    Start-Sleep -Seconds 5

    $Installed = @(Get-DebuggerCandidates)

    if ($Installed.Count -eq 0) {
        throw "Debugger executables were not found after install"
    }

    $Installed | Sort-Object Version -Descending | ForEach-Object {
        Write-Host "$($_.Name)  $($_.VersionText)  $($_.Path)"
    }

    $Highest = Get-HighestDebuggerVersion
    if ($null -eq $Highest) {
        throw "Unable to determine installed debugger version"
    }

    Write-Host "Highest detected debugger version $($Highest.VersionText)"

    if ($Highest.Version -lt $MinimumVersion) {
        throw "Installed debugger version $($Highest.VersionText) is still below required minimum $MinimumVersion"
    }

    Write-Section "Completed"
    Write-Host "Debugger install or update completed successfully"
}
catch {
    Write-Section "Install failed"
    Write-Host $_.Exception.Message
    exit 1
