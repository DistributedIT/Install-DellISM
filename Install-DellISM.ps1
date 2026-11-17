# Install-DellISM.ps1
# Installs or upgrades Dell iDRAC Service Module (iSM) on Windows Server PowerEdge hosts.
# Unattended, for ConnectWise RMM (Asio), running as SYSTEM. No parameters required.
#
# Behaviour
#   - Non-Dell / VM / client OS            -> SKIPPED, exit 0
#   - PowerEdge gen + OS with no Dell pkg  -> SKIPPED, exit 0
#   - PowerEdge model the script can't map -> UNKNOWN MODEL, exit 2 (needs a table update)
#   - Same or newer iSM already installed  -> SKIPPED, exit 0
#   - Install / upgrade                    -> SUCCESS, exit 0 (3010 = success, reboot pending, still exit 0)
#   - Any real failure                     -> exit 1
#   - Not elevated                         -> exit 3
#
# Package table (Dell Windows web packs, SHA-256 from each driver page)
#   6.1.0.0  V2H2D  15G/16G/17G  Server 2022/2025
#   5.4.1.1  GC9TH  14G/15G/16G  Server 2019/2022/2025
#   4.3.0.0  N6KY8  13G/14G/15G  Server 2019/2022
#   4.2.0.0  56GJN  12G-15G      Server 2016/2019/2022
#
# Logs
#   C:\ProgramData\DellISM\Install-DellISM.log      (this script, appended)
#   C:\ProgramData\DellISM\msi-<timestamp>.log      (msiexec /L*V)
#
# Optional RMM toggle. Asio substitutes the placeholder text before execution; an unsubstituted
# literal or blank is treated as false. Set to true to reinstall even if already current.
$ForceReinstallRaw = '@ForceReinstall@'

$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# Asio launches 32-bit PowerShell. Relaunch in 64-bit so registry and msiexec behave normally.
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -and $PSCommandPath) {
    $sysnativePs = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $sysnativePs) {
        & $sysnativePs -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
        if ($null -eq $LASTEXITCODE) { Write-Host 'ERROR: 64-bit PowerShell relaunch failed to start.'; exit 1 }
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = 'Stop'
$KeepWorkDir = $false

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$BaseDir    = Join-Path $env:ProgramData 'DellISM'
$WorkDir    = Join-Path $BaseDir 'work'
$LogFile    = Join-Path $BaseDir 'Install-DellISM.log'
$MsiLog     = Join-Path $BaseDir ("msi-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Worst case: download ~180 (30 s connect + 120 s deadline + one 30 s stalled read) + extract 60
# + mutex 60 + 1618 retry sleep 30 + msiexec 300 + service 60 = ~690 s (11.5 min), inside a
# 15 min Asio task timeout after ~3 min agent overhead.
$DownloadTimeoutSec   = 120
$MsiMutexWaitSec      = 60
$MsiexecWaitSec       = 300
$MsiRetryOn1618       = 2
$ExtractTimeoutSec    = 60
$ServiceWaitSec       = 60

# Ordered newest-first. First package whose Gens and OS both match wins.
$Packages = @(
    @{ Version = '6.1.0.0'; Gens = @(15, 16, 17); OS = @('2022', '2025')
       Url = 'https://dl.dell.com/FOLDER14150572M/1/OM-iSM-Dell-Web-X64-6.1.0.0-4106.exe'
       Sha256 = 'C00A88408D7FA36F9686BFA706E3D9FEC7741BA60638E3D3EEFC8F5D557CC42A' },
    @{ Version = '5.4.1.1'; Gens = @(14, 15, 16); OS = @('2019', '2022', '2025')
       Url = 'https://dl.dell.com/FOLDER13421780M/1/OM-iSM-Dell-Web-X64-5.4.1.1-3973.exe'
       Sha256 = 'A9C5D567E7CE73AE69955F97AA8F1835AB145696BD8FAD4B4624BE02AD637278' },
    @{ Version = '4.3.0.0'; Gens = @(13, 14, 15); OS = @('2019', '2022')
       Url = 'https://dl.dell.com/FOLDER08843138M/1/OM-iSM-Dell-Web-X64-4.3.0.0-2813_A01.exe'
       Sha256 = '27712804AB14E210D19BF399EF59A95D42AFB91A6AC519118CE4AF4E78137E69' },
    @{ Version = '4.2.0.0'; Gens = @(12, 13, 14, 15); OS = @('2016', '2019', '2022')
       Url = 'https://dl.dell.com/FOLDER08068411M/1/OM-iSM-Dell-Web-X64-4.2.0.0-2581_A00.exe'
       Sha256 = 'A6129BCCE4BDD71D95114B9B6788F1F90749BCE7E1DA82A4B0ADDA4A832103CE' }
)

# Models where "second digit + 10" does not give the generation (per Dell KB 000137343).
# 0 = no iDRAC / not an iSM target.
$ModelExceptions = @{
    'XR11' = 15; 'XR12' = 15; 'XR2' = 14; 'C4140' = 14; 'XE7100' = 14; 'C4130' = 13
    'HS5610' = 16; 'HS5620' = 16
    'T20' = 0; 'T30' = 0; 'T40' = 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    # Write-Host, not Write-Output: Write-Output inside helper functions leaks log lines into their return values.
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding ASCII -ErrorAction SilentlyContinue } catch { }
}

function ConvertTo-VersionSafe {
    # Returns Major.Minor.Build only. Dell registers DisplayVersion as 3 parts on some releases
    # (e.g. 3.4.0) and 4 parts on others (e.g. 4.2.0.0), and Windows Installer itself only
    # compares the first 3 fields, so the 4th is ignored for skip/verify decisions.
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.'))
    while ($parts.Count -lt 3) { $parts += '0' }
    try { return [version]($parts[0..2] -join '.') } catch { return $null }
}

function Get-InstalledISM {
    # Reads both 64-bit and 32-bit uninstall views regardless of process bitness.
    $best = $null
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $hive = $null
        try {
            $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $key = $hive.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $key) { continue }
            foreach ($name in $key.GetSubKeyNames()) {
                $sub = $key.OpenSubKey($name)
                if (-not $sub) { continue }
                $dn = [string]$sub.GetValue('DisplayName')
                if ($dn -like '*iDRAC Service Module*') {
                    $ver = ConvertTo-VersionSafe ([string]$sub.GetValue('DisplayVersion'))
                    $entry = [pscustomobject]@{
                        DisplayName    = $dn
                        DisplayVersion = [string]$sub.GetValue('DisplayVersion')
                        Version        = $ver
                        ProductCode    = $name
                        View           = $view.ToString()
                    }
                    if (-not $best -or ($ver -and (-not $best.Version -or $ver -gt $best.Version))) { $best = $entry }
                }
                $sub.Close()
            }
            $key.Close()
        }
        catch { }
        finally { if ($hive) { $hive.Close() } }
    }
    return $best
}

function Get-ISMService {
    # Dell documents the Windows service as "DSM iDRAC Service Module" (iSM User's Guide, FAQ).
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*iDRAC Service Module*' -or $_.Name -like '*iDRAC Service Module*' -or $_.Name -eq 'dcismeng' } |
        Select-Object -First 1
}

function Get-PowerEdgeGeneration {
    param([string]$Model)
    $m = [regex]::Match($Model, 'PowerEdge\s+([A-Za-z]+)(\d+)([A-Za-z0-9]*)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $null }
    $code = ($m.Groups[1].Value + $m.Groups[2].Value).ToUpper()
    if ($ModelExceptions.ContainsKey($code)) { return [int]$ModelExceptions[$code] }
    $digits = $m.Groups[2].Value
    if ($digits.Length -lt 2) { return $null }
    # Dell naming: second digit of the numeric part is the series (3=13G, 4=14G ... 7=17G).
    return 10 + [int][string]$digits[1]
}

function Test-MsiMutexFree {
    # Returns $true when no Windows Installer operation is in progress.
    $mtx = $null
    try {
        $mtx = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
        return $false
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] { return $true }
    catch [System.UnauthorizedAccessException] { return $false }
    catch { return $true }
    finally { if ($mtx) { $mtx.Close() } }
}

function Invoke-Download {
    # HttpWebRequest stream copy with a wall-clock deadline. On PS 5.1, Invoke-WebRequest -TimeoutSec
    # only bounds connect + response headers, not the body transfer, so it can't enforce a budget.
    param([string]$Url, [string]$Destination)
    $deadline = (Get-Date).AddSeconds($DownloadTimeoutSec)
    $resp = $null; $inStream = $null; $outStream = $null
    try {
        if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
        $req.AllowAutoRedirect = $true
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 30000
        $resp = $req.GetResponse()
        $inStream = $resp.GetResponseStream()
        $outStream = [System.IO.File]::Create($Destination)
        $buffer = New-Object byte[] 65536
        while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $read)
            if ((Get-Date) -gt $deadline) { throw "Download exceeded $DownloadTimeoutSec s." }
        }
        $outStream.Close(); $outStream = $null
        $size = (Get-Item $Destination).Length
        if ($size -lt 1000000) { throw "Downloaded file is only $size bytes." }
        Write-Log ("Download OK ({0:N1} MB)." -f ($size / 1MB))
        return $true
    }
    catch {
        Write-Log "Download failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($outStream) { $outStream.Close() }
        if ($inStream) { $inStream.Close() }
        if ($resp) { $resp.Close() }
    }
}

function Find-Msi {
    param([string[]]$Roots)
    foreach ($root in $Roots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -Path $root -Filter 'iDRACSvcMod.msi' -Recurse -ErrorAction SilentlyContinue |
               Sort-Object CreationTime -Descending | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Expand-WebPack {
    param([string]$ExePath, [string]$Destination)
    # Dell's Windows web pack is a WinZip self-extractor. Try reading it as a zip first,
    # then fall back to the WinZip SFX unattended switch: <exe> /auto <folder>.
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ExePath, $Destination)
        $msi = Find-Msi -Roots @($Destination)
        if ($msi) { Write-Log 'Extracted web pack via zip.'; return $msi }
        Write-Log 'Zip extraction produced no iDRACSvcMod.msi; trying self-extractor.'
    }
    catch {
        Write-Log "Zip extraction failed ($($_.Exception.Message)); trying self-extractor."
    }

    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    $startTime = Get-Date
    $sfx = Start-Process -FilePath $ExePath -ArgumentList "/auto `"$Destination`"" -PassThru -WindowStyle Hidden
    $null = $sfx.Handle   # cache handle so ExitCode is populated after WaitForExit(ms)
    if (-not $sfx.WaitForExit($ExtractTimeoutSec * 1000)) {
        try { $sfx | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
        Write-Log "Self-extractor did not finish within $ExtractTimeoutSec s and was stopped."
    }
    else {
        Write-Log "Self-extractor exited with code $($sfx.ExitCode)."
    }
    $msi = Find-Msi -Roots @($Destination)
    if (-not $msi) {
        # Some SFX builds ignore the folder argument and unpack to C:\OpenManage. Only accept a copy
        # created by this run (CreationTime, since LastWriteTime is carried over from the archive).
        $alt = Find-Msi -Roots @((Join-Path $env:SystemDrive 'OpenManage'))
        if ($alt -and $alt.CreationTime -ge $startTime.AddMinutes(-1)) { $msi = $alt }
        elseif ($alt) { Write-Log "Ignoring pre-existing MSI at $($alt.FullName)." }
    }
    return $msi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    New-Item -Path $BaseDir -ItemType Directory -Force | Out-Null
    Write-Log '----- Install-DellISM start -----'

    # Elevation
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log 'ERROR: Not running elevated.'
        exit 3
    }

    $forceReinstall = ("$ForceReinstallRaw".Trim() -match '^(true|1|yes)$')
    $is64Proc = [Environment]::Is64BitProcess
    Write-Log "PowerShell $($PSVersionTable.PSVersion) | 64-bit process: $is64Proc | user: $env:USERNAME | force: $forceReinstall"

    # Applicability
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$osInfo.BuildNumber
    $manufacturer = [string]$cs.Manufacturer
    $model = ([string]$cs.Model).Trim()
    $sku = [string]$cs.SystemSKUNumber

    Write-Log "Host: $env:COMPUTERNAME | $manufacturer | $model | SKU: $sku | $($osInfo.Caption) build $build"

    if ($manufacturer -notmatch 'Dell') {
        Write-Log 'SKIPPED: Not Dell hardware (or a VM).'
        exit 0
    }
    if ($model -notmatch 'PowerEdge') {
        # SMBIOS SKU string on PowerEdge carries "ModelName=PowerEdge Rxxx"; use it if Model is blank or odd.
        $skuMatch = [regex]::Match($sku, 'ModelName=(PowerEdge[^;]+)')
        if ($skuMatch.Success) {
            $model = $skuMatch.Groups[1].Value.Trim()
            Write-Log "Model taken from SMBIOS SKU string: $model"
        }
        else {
            Write-Log 'SKIPPED: Dell system but not a PowerEdge (or a VM).'
            exit 0
        }
    }
    if ([int]$osInfo.ProductType -eq 1) {
        Write-Log 'SKIPPED: Client OS. iSM targets Windows Server.'
        exit 0
    }

    $osKey = switch ($build) {
        14393 { '2016' }
        17763 { '2019' }
        20348 { '2022' }
        26100 { '2025' }
        default { if ($build -gt 26100) { '2025' } else { "build$build" } }
    }

    # Generation
    $gen = Get-PowerEdgeGeneration -Model $model
    if ($null -eq $gen) {
        Write-Log "UNKNOWN MODEL: Could not derive PowerEdge generation from '$model'. Add it to `$ModelExceptions."
        exit 2
    }
    if ($gen -eq 0) {
        Write-Log "SKIPPED: '$model' has no iDRAC; iSM is not applicable."
        exit 0
    }
    Write-Log "PowerEdge generation: ${gen}G | OS key: $osKey"

    # Package selection
    $pkg = $null
    foreach ($candidate in $Packages) {
        if (($candidate.Gens -contains $gen) -and ($candidate.OS -contains $osKey)) { $pkg = $candidate; break }
    }
    if (-not $pkg) {
        Write-Log "SKIPPED: Dell publishes no iSM for Windows for ${gen}G on Windows Server $osKey. Nothing to install."
        exit 0
    }
    $targetVersion = ConvertTo-VersionSafe $pkg.Version
    Write-Log "Target iSM: $($pkg.Version) (compared as $targetVersion)"

    # Existing install
    $installed = Get-InstalledISM
    if ($installed) {
        Write-Log "Installed: '$($installed.DisplayName)' $($installed.DisplayVersion) ($($installed.View)) product $($installed.ProductCode)"
        $svcNow = Get-ISMService
        $svcState = if ($svcNow) { "$($svcNow.Name) is $($svcNow.Status)" } else { 'service not found' }
        if ($installed.Version -and $installed.Version -gt $targetVersion) {
            # Never downgrade, even with force: the MSI blocks it (ISPreventDowngrade) and returns 1603.
            Write-Log "SKIPPED: installed iSM is newer than this host's target ($svcState)."
            exit 0
        }
        if ($installed.Version -and $installed.Version -eq $targetVersion -and -not $forceReinstall) {
            Write-Log "SKIPPED: iSM already at target ($svcState)."
            exit 0
        }
        $sameVersionReinstall = ($installed.Version -and $installed.Version -eq $targetVersion -and $forceReinstall)
        if (-not $installed.Version) { Write-Log 'Installed version unparseable; proceeding with install.' }
    }
    else {
        Write-Log 'iSM not installed.'
    }

    if (-not $sameVersionReinstall) { $sameVersionReinstall = $false }

    # Stage
    if (Test-Path $WorkDir) { Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
    $exePath = Join-Path $WorkDir 'iSM-WebPack.exe'
    $extractPath = Join-Path $WorkDir 'extract'

    Write-Log "Downloading $($pkg.Url)"
    if (-not (Invoke-Download -Url $pkg.Url -Destination $exePath)) {
        Write-Log 'ERROR: Download failed.'
        exit 1
    }

    $actualSha = (Get-FileHash -Path $exePath -Algorithm SHA256).Hash
    if ($actualSha.ToUpper() -ne $pkg.Sha256.ToUpper()) {
        Write-Log "ERROR: SHA-256 mismatch. Expected $($pkg.Sha256) got $actualSha"
        exit 1
    }
    Write-Log 'SHA-256 verified.'

    $msi = Expand-WebPack -ExePath $exePath -Destination $extractPath
    if (-not $msi) {
        Write-Log 'ERROR: iDRACSvcMod.msi not found after extraction.'
        exit 1
    }
    Write-Log "MSI: $($msi.FullName)"

    # Wait for Windows Installer to be free
    $waited = 0
    while (-not (Test-MsiMutexFree) -and $waited -lt $MsiMutexWaitSec) {
        if ($waited -eq 0) { Write-Log 'Another Windows Installer operation is running; waiting.' }
        Start-Sleep -Seconds 10
        $waited += 10
    }
    if (-not (Test-MsiMutexFree)) {
        Write-Log "ERROR: Windows Installer still busy after $MsiMutexWaitSec s."
        exit 1
    }

    # Install (MSI handles upgrade over an older iSM via major upgrade; no uninstall-first step needed)
    $msiArgs = "/i `"$($msi.FullName)`" /qn /norestart REBOOT=ReallySuppress /L*V `"$MsiLog`""
    # Same ProductCode already installed: plain /i is a no-op maintenance run, so force a real reinstall.
    if ($sameVersionReinstall) { $msiArgs += ' REINSTALL=ALL REINSTALLMODE=vomus' }
    Write-Log "Running: msiexec.exe $msiArgs"
    $rc = $null
    for ($msiTry = 1; $msiTry -le $MsiRetryOn1618; $msiTry++) {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -PassThru -WindowStyle Hidden
        $null = $proc.Handle   # cache handle so ExitCode is populated after WaitForExit(ms)
        if (-not $proc.WaitForExit($MsiexecWaitSec * 1000)) {
            Write-Log "ERROR: msiexec did not finish within $MsiexecWaitSec s. Left running; check $MsiLog"
            $KeepWorkDir = $true   # msiexec is still using the extracted files
            exit 1
        }
        $rc = $proc.ExitCode
        if ($rc -ne 1618 -or $msiTry -eq $MsiRetryOn1618) { break }
        Write-Log "msiexec returned 1618 (another install in progress); retry $msiTry of $MsiRetryOn1618 after 30 s."
        Start-Sleep -Seconds 30
    }

    $rebootPending = $false
    switch ($rc) {
        0    { Write-Log 'msiexec exit 0: install completed.' }
        3010 { Write-Log 'msiexec exit 3010: install completed, reboot pending (not initiated).'; $rebootPending = $true }
        1641 { Write-Log 'msiexec exit 1641: install completed, installer requested reboot (suppressed).'; $rebootPending = $true }
        1618 { Write-Log "ERROR: msiexec still 1618 after retries. Log: $MsiLog"; exit 1 }
        default { Write-Log "ERROR: msiexec exit $rc. Log: $MsiLog"; exit 1 }
    }

    # Verify
    $installed = Get-InstalledISM
    if (-not $installed) {
        Write-Log "ERROR: iSM missing from uninstall registry after install. Log: $MsiLog"
        exit 1
    }
    Write-Log "Installed now: '$($installed.DisplayName)' $($installed.DisplayVersion)"
    if ($installed.Version -and $installed.Version -lt $targetVersion) {
        Write-Log "ERROR: msiexec exit $rc but installed version is still below target $targetVersion. Log: $MsiLog"
        exit 1
    }

    $svc = $null
    $elapsed = 0
    while ($elapsed -lt $ServiceWaitSec) {
        $svc = Get-ISMService
        if ($svc -and $svc.Status -eq 'Running') { break }
        if ($svc -and $svc.Status -eq 'Stopped' -and $elapsed -ge 20) {
            try { Start-Service -Name $svc.Name -ErrorAction Stop; Write-Log "Started service '$($svc.Name)'." } catch { }
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    # Re-read: if Start-Service only succeeded on the last loop pass, $svc still holds the old status.
    if (-not ($svc -and $svc.Status -eq 'Running')) { $svc = Get-ISMService }

    # Informational only; must never turn a good install into a failure.
    try {
        $usbNic = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -like '*Remote NDIS*' } | Select-Object -First 1
        if ($usbNic) { Write-Log "iDRAC USB NIC: $($usbNic.Name) ($($usbNic.Status))" }
        else { Write-Log 'NOTE: No Remote NDIS adapter yet. Confirm OS to iDRAC Pass-through (USB NIC) is enabled in iDRAC.' }
    }
    catch { Write-Log "NOTE: Could not query network adapters ($($_.Exception.Message))." }

    if ($svc -and $svc.Status -eq 'Running') {
        Write-Log "Service '$($svc.DisplayName)' running."
    }
    elseif ($rebootPending) {
        Write-Log 'Service not running yet; expected until reboot.'
    }
    else {
        $svcText = if ($svc) { "'$($svc.DisplayName)' is $($svc.Status)" } else { 'no iSM service found' }
        Write-Log "ERROR: iSM installed but $svcText after $ServiceWaitSec s. Log: $MsiLog"
        exit 1
    }

    if ($rebootPending) { Write-Log 'SUCCESS (reboot pending, not initiated).' } else { Write-Log 'SUCCESS' }
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { Write-Log "  at line $($_.InvocationInfo.ScriptLineNumber)" }
    exit 1
}
finally {
    if (-not $KeepWorkDir -and $WorkDir -and (Test-Path $WorkDir)) { Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}
