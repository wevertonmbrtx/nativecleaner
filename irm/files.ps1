# files.ps1 — Limpeza de arquivos, caches do sistema e navegadores
# Uso: iex (irm https://bit.ly/SEU-LINK)
# Log: %TEMP%\xoptimizer.log

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# IMPORTANTE: trocar pela URL raw real após hospedar no GitHub
$script:SourceUrl = 'https://raw.githubusercontent.com/wevertonmbrtx/LIMP-Regex/refs/heads/main/irm/files.ps1'
$script:LogFile   = "$env:TEMP\files_cleaner.log"

# ===== INFRA COMPARTILHADA =====

function Write-Log {
    param([string]$Message, [string]$Level = 'i')
    $tag = switch ($Level) {
        'i' { '[i]' } 'w' { '[!]' } 'e' { '[X]' } 'o' { '[v]' } default { '[i]' }
    }
    $line = '[{0}] {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $tag, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch {}
}

function Get-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return ([System.Security.Principal.WindowsPrincipal]$id).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DirSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        return $fso.GetFolder($Path).Size
    } catch { return 0 }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    elseif ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    elseif ($Bytes -gt 0)  { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    else                   { return '0 Bytes' }
}

function Invoke-SelfElevation {
    if (Get-IsAdmin) { return $true }
    Write-Log 'Elevação necessária. Re-baixando script para temp...' 'i'

    $tempScript = "$env:TEMP\xopt_$(Get-Random).ps1"
    $elevated = $false

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $content = Invoke-RestMethod -Uri $script:SourceUrl -UseBasicParsing -ErrorAction Stop
        Set-Content -LiteralPath $tempScript -Value $content -Encoding UTF8 -Force

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = 'powershell.exe'
        $psi.Arguments       = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tempScript`""
        $psi.Verb            = 'runas'
        $psi.UseShellExecute = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($proc) {
            $proc.WaitForExit()
            Write-Log "Instância elevada finalizada (exit $($proc.ExitCode))" 'o'
            $elevated = $true
        }
    } catch {
        Write-Log "Falha na elevação: $_" 'w'
    }

    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue

    if ($elevated) { exit 0 }
    return $false
}

# ===== LIMPEZA =====

function Close-Apps {
    $targetApps = @('chrome', 'msedge', 'msedgewebview', 'msedgewebview2', 'opera', 'brave',
                    'firefox', 'discord', 'teams', 'ms-teams', 'code', 'blitz')
    foreach ($procName in $targetApps) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($procs) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Log "Encerrado: $procName" 'w'
        }
    }
}

function Invoke-DnsCleanup {
    try {
        if (Get-Command 'Clear-DnsClientCache' -ErrorAction SilentlyContinue) {
            Clear-DnsClientCache -ErrorAction Stop
        } else {
            $p = Start-Process ipconfig -ArgumentList '/flushdns' -NoNewWindow -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "ipconfig retornou $($p.ExitCode)" }
        }
        Write-Log 'Cache DNS limpo' 'o'
    } catch {
        Write-Log "Falha DNS: $_" 'e'
    }
}

function Invoke-StoreCacheReset {
    try {
        $job = Start-Job { Start-Process 'wsreset.exe' -WindowStyle Hidden -Wait }
        if (-not (Wait-Job $job -Timeout 15)) {
            Stop-Job $job
            Stop-Process -Name 'wsreset' -Force -ErrorAction SilentlyContinue
            Write-Log 'MS Store resetada (timeout)' 'o'
        } else {
            Remove-Job $job -Force
            Stop-Process -Name 'WinStore.App' -Force -ErrorAction SilentlyContinue
            Write-Log 'MS Store resetada' 'o'
        }
    } catch {
        Write-Log "Falha MS Store: $_" 'e'
    }
}

function Invoke-ThumbnailCacheReset {
    try {
        $thumbPath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
        if (-not (Test-Path -LiteralPath $thumbPath)) { return }

        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1

        $freed = 0
        Get-ChildItem -LiteralPath $thumbPath -Filter '*.db' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $sz = $_.Length
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                $freed += $sz
            } catch {}
        }

        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Write-Log "Thumbnail cache: $(Format-Size -Bytes $freed)" 'o'
    } catch {
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-Log "Erro thumbnails: $_" 'e'
    }
}

function Invoke-SystemCleanup {
    $result = [PSCustomObject]@{ TotalFreedBytes = 0; ItemsCleaned = 0; ItemsFailed = 0 }
    $isAdmin = Get-IsAdmin

    $roaming  = $env:APPDATA
    $local    = $env:LOCALAPPDATA
    $localLow = "$env:USERPROFILE\AppData\LocalLow"
    $win      = $env:windir
    $temp     = $env:TEMP

    $targets = @()

    # Electron apps
    $electronApps = @(
        @{ Name = 'Discord'; Path = "$roaming\discord" },
        @{ Name = 'VSCode';  Path = "$roaming\Code" },
        @{ Name = 'Teams';   Path = "$roaming\Microsoft\Teams" },
        @{ Name = 'Blitz';   Path = "$roaming\Blitz" }
    )
    $electronFolders = @('Cache', 'Code Cache', 'GPUCache', 'gpu_logs', 'DawnGraphiteCache', 'DawnWebGPUCache')
    foreach ($app in $electronApps) {
        foreach ($sub in $electronFolders) {
            $targets += [PSCustomObject]@{ Path = "$($app.Path)\$sub"; Name = "$($app.Name) $sub" }
        }
    }

    # Windows caches (requer admin)
    if ($isAdmin) {
        $winSubs = @('Caches', 'History\low', 'IECompatCache', 'IECompatUaCache',
                     'IEDownloadHistory', 'INetCache', 'Temporary Internet Files',
                     'WebCache', 'ActionCenterCache', 'AppCache',
                     'WER\ReportQueue', 'WER\ReportArchive', 'WER\Temp')
        foreach ($p in $winSubs) {
            $targets += [PSCustomObject]@{ Path = "$win\$p"; Name = "Windows $p" }
        }
        $targets += [PSCustomObject]@{ Path = "$env:SystemRoot\Prefetch"; Name = 'Windows Prefetch' }
    }

    # Microsoft local caches
    $msPaths = @('GraphicsCache', 'FontCache', 'IdentityCache', 'Package Cache',
                 'Windows Defender\Cache', 'Windows Search', 'OneDrive\Cache', 'OneDrive\logs')
    foreach ($p in $msPaths) {
        $targets += [PSCustomObject]@{ Path = "$local\Microsoft\$p"; Name = "Microsoft $p" }
    }

    # Diversos
    $targets += [PSCustomObject]@{ Path = $temp; Name = 'User Temp' }
    $targets += [PSCustomObject]@{ Path = "$localLow\Temp"; Name = 'LocalLow Temp' }
    $targets += [PSCustomObject]@{ Path = "$local\SquirrelTemp"; Name = 'Squirrel Temp' }
    $targets += [PSCustomObject]@{ Path = "$local\Microsoft\Outlook\RoamCache"; Name = 'Outlook RoamCache' }
    $targets += [PSCustomObject]@{ Path = "$local\Microsoft\Teams\cache"; Name = 'Teams Local Cache' }

    foreach ($item in $targets) {
        if (-not (Test-Path -LiteralPath $item.Path)) { continue }
        try {
            $before = Get-DirSize -Path $item.Path
            if ($before -gt 0) {
                Get-ChildItem -LiteralPath $item.Path -Recurse -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                $after = Get-DirSize -Path $item.Path
                $freed = $before - $after
                if ($freed -gt 0) {
                    $result.TotalFreedBytes += $freed
                    $result.ItemsCleaned++
                    Write-Log "$($item.Name): $(Format-Size -Bytes $freed)" 'o'
                }
            }
        } catch {
            $result.ItemsFailed++
            Write-Log "Falha: $($item.Name)" 'w'
        }
    }

    # Lixeira
    try {
        $recyclePath = "$env:SystemDrive\`$Recycle.Bin"
        $rb = Get-DirSize -Path $recyclePath
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        if ($rb -gt 0) {
            $result.TotalFreedBytes += $rb
            Write-Log "Lixeira: $(Format-Size -Bytes $rb)" 'o'
        }
    } catch {}

    return $result
}

function Invoke-BrowserCleanup {
    $result = [PSCustomObject]@{ TotalFreedBytes = 0; BrowsersCleaned = 0 }

    $browserConfig = @(
        @{ Name = 'Google Chrome';  Path = "$env:LOCALAPPDATA\Google\Chrome\User Data";               Type = 'chromium'; Targets = @('Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'Service Worker', 'CacheStorage') },
        @{ Name = 'Microsoft Edge'; Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data";              Type = 'chromium'; Targets = @('Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'Service Worker', 'CacheStorage') },
        @{ Name = 'Edge WebView';   Path = "$env:LOCALAPPDATA\Microsoft\EdgeWebView\User Data";       Type = 'chromium'; Targets = @('Cache', 'Code Cache', 'GPUCache', 'ShaderCache') },
        @{ Name = 'Brave';          Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; Type = 'chromium'; Targets = @('Cache', 'Code Cache', 'GPUCache', 'ShaderCache') },
        @{ Name = 'Opera GX';       Path = "$env:LOCALAPPDATA\Opera Software\Opera GX Stable";        Type = 'opera';    Targets = @('Cache', 'System Cache', 'GPUCache', 'ShaderCache') },
        @{ Name = 'Opera Stable';   Path = "$env:LOCALAPPDATA\Opera Software\Opera Stable";           Type = 'opera';    Targets = @('Cache', 'System Cache', 'GPUCache', 'ShaderCache') },
        @{ Name = 'Firefox';        Path = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles";              Type = 'firefox';  Targets = @('cache2', 'startupCache', 'thumbnails', 'jumpListCache') }
    )

    foreach ($b in $browserConfig) {
        if (-not (Test-Path -LiteralPath $b.Path)) { continue }
        $browserFreed = 0
        $profiles = @()

        switch ($b.Type) {
            'chromium' {
                $profiles = Get-ChildItem -LiteralPath $b.Path -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '^(System Profile|Guest Profile|Crashpad|GrShaderCache|ShaderCache|WidevineCdm|pnacl|Subresource Filter|hyphen-data|ZxcvbnData|EVWhitelist|SSLErrorAssistant|SwReporter|BrowserMetrics|Safe Browsing|Floc|Segmentation Platform|OptimizationHints|OnDeviceHeadSuggest|PepperFlash|MEIPreload|CertificateTransparency|NativeMessagingHosts|extensions_crx_cache|FileTypePolicies|OriginTrials|PKIMetadata)$' }
            }
            'opera'   { $profiles = @(Get-Item -LiteralPath $b.Path -ErrorAction SilentlyContinue) }
            'firefox' { $profiles = Get-ChildItem -LiteralPath $b.Path -Directory -ErrorAction SilentlyContinue }
        }

        foreach ($p in $profiles) {
            foreach ($t in $b.Targets) {
                $tp = Join-Path -Path $p.FullName -ChildPath $t
                if (Test-Path -LiteralPath $tp) {
                    try {
                        $before = Get-DirSize -Path $tp
                        if ($before -gt 0) {
                            Get-ChildItem -LiteralPath $tp -Recurse -Force -ErrorAction SilentlyContinue |
                                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                            $after = Get-DirSize -Path $tp
                            $browserFreed += ($before - $after)
                        }
                    } catch {}
                }
            }
        }

        $result.TotalFreedBytes += $browserFreed
        if ($browserFreed -gt 0) {
            $result.BrowsersCleaned++
            Write-Log "$($b.Name): $(Format-Size -Bytes $browserFreed)" 'o'
        }
    }

    return $result
}

# ===== MAIN =====

Write-Log '===== files.ps1 iniciado =====' 'i'
$start = Get-Date

$isAdmin = Invoke-SelfElevation
if ($isAdmin) { Write-Log 'Modo: ADMIN' 'o' } else { Write-Log 'Modo: USUÁRIO LIMITADO' 'w' }

Close-Apps
Invoke-ThumbnailCacheReset
Invoke-StoreCacheReset
Invoke-DnsCleanup
$sys = Invoke-SystemCleanup
$brw = Invoke-BrowserCleanup

$total = $sys.TotalFreedBytes + $brw.TotalFreedBytes
$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
Write-Log "Total liberado: $(Format-Size -Bytes $total) em ${elapsed}s" 'o'
Write-Log '===== files.ps1 finalizado =====' 'i'
