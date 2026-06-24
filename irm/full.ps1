# full.ps1 — Limpeza completa: arquivos + navegadores + RAM
# Uso: irm bit.ly/wgitncf | iex
# Log: %TEMP%\ncf.log

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$script:SourceUrl = 'https://raw.githubusercontent.com/wevertonmbrtx/nativecleaner/refs/heads/main/irm/full.ps1'
$script:LogFile   = "$env:TEMP\ncf.log"

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

# ===== LIMPEZA DE ARQUIVOS =====

function Close-Apps {
    $targetApps = @('chrome', 'msedge', 'msedgewebview2', 'opera', 'brave',
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
            Remove-Job $job -Force
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
    $sysd     = $env:SYSTEMDRIVE
    $win      = $env:SYSTEMROOT
    $temp     = $env:TEMP

    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" -Name * -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery" -Name * -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths" -Name * -ErrorAction SilentlyContinue

    $targets = @()

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

    if ($isAdmin) {
        $winSubs = @('Caches', 'History\low', 'IECompatCache', 'IECompatUaCache',
                     'IEDownloadHistory', 'INetCache', 'Temporary Internet Files',
                     'WebCache', 'ActionCenterCache', 'AppCache',
                     'WER\ReportQueue', 'WER\ReportArchive', 'WER\Temp')
        foreach ($p in $winSubs) {
            $targets += [PSCustomObject]@{ Path = "$sysd\$p"; Name = "Windows $p" }
        }
        $targets += [PSCustomObject]@{ Path = "$win\Prefetch"; Name = 'Windows Prefetch' }
        $targets += [PSCustomObject]@{ Path = "$win\Temp";    Name = 'Windows Temp' }
    }

    $msPaths = @('GraphicsCache', 'FontCache', 'IdentityCache', 'Package Cache',
                 'Windows Defender\Cache', 'Windows Search', 'OneDrive\Cache', 'OneDrive\logs')
    foreach ($p in $msPaths) {
        $targets += [PSCustomObject]@{ Path = "$local\Microsoft\$p"; Name = "Microsoft $p" }
    }

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

# ===== POWER PLAN =====

function Invoke-UltimatePerformance {
    $sourceGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $targetGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb62'

    $active = powercfg /getactivescheme 2>$null
    if ($active -match $targetGuid) {
        Write-Log 'Desempenho Máximo já está ativo' 'i'
        return
    }

    $list = powercfg /list 2>$null
    if ($list -match $targetGuid) {
        powercfg /setactive $targetGuid 2>$null
        Write-Log 'Desempenho Máximo ativado (plano já existia)' 'o'
        return
    }

    powercfg /duplicatescheme $sourceGuid $targetGuid 2>$null
    powercfg /setactive $targetGuid 2>$null
    Write-Log 'Desempenho Máximo criado e ativado' 'o'
}

# ===== RAM =====

function Invoke-RamCleanup {
    $result = [PSCustomObject]@{
        Success = $false; Executed = $false; TotalFreedBytes = 0
        ErrorOccurred = $false; Message = ''
    }

    if (-not (Get-IsAdmin)) {
        $result.Message = 'Requer admin'
        Write-Log $result.Message 'w'
        return $result
    }

    if (-not ([System.Management.Automation.PSTypeName]'NativeRamTools').Type) {
        try {
            Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct SYSTEM_CACHE_INFORMATION {
    public uint CurrentSize; public uint PeakSize; public uint PageFaultCount;
    public uint MinimumWorkingSet; public uint MaximumWorkingSet;
    public uint Unused1; public uint Unused2; public uint Unused3; public uint Unused4;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct SYSTEM_CACHE_INFORMATION_64 {
    public long CurrentSize; public long PeakSize; public long PageFaultCount;
    public long MinimumWorkingSet; public long MaximumWorkingSet;
    public long Unused1; public long Unused2; public long Unused3; public long Unused4;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }

[StructLayout(LayoutKind.Sequential)]
public struct MEMORYSTATUSEX {
    public uint dwLength; public uint dwMemoryLoad;
    public ulong ullTotalPhys; public ulong ullAvailPhys;
    public ulong ullTotalPageFile; public ulong ullAvailPageFile;
    public ulong ullTotalVirtual; public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
}

public class NativeRamTools {
    const int SE_PRIVILEGE_ENABLED = 2;

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);

    [DllImport("ntdll.dll")]
    public static extern uint NtSetSystemInformation(int InfoClass, IntPtr Info, int Length);

    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hwProc);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    public static bool SetPrivilege(string name) {
        try {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent(TokenAccessLevels.Query | TokenAccessLevels.AdjustPrivileges)) {
                TokPriv1Luid tp; tp.Count = 1; tp.Luid = 0L; tp.Attr = SE_PRIVILEGE_ENABLED;
                if (!LookupPrivilegeValue(null, name, ref tp.Luid)) return false;
                if (!AdjustTokenPrivileges(id.Token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
                return true;
            }
        } catch { return false; }
    }

    public static long GetAvailablePhysicalMemory() {
        MEMORYSTATUSEX ms = new MEMORYSTATUSEX();
        ms.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        if (GlobalMemoryStatusEx(ref ms)) return (long)ms.ullAvailPhys;
        return -1;
    }

    public static int[] EmptyAllWorkingSets() {
        int trimmed = 0, skipped = 0;
        foreach (Process p in Process.GetProcesses()) {
            if (p.Id == 0 || p.Id == 4) { skipped++; continue; }
            try {
                if (!p.HasExited) { EmptyWorkingSet(p.Handle); trimmed++; }
            } catch { skipped++; }
        }
        return new int[] { trimmed, skipped };
    }

    static uint MemoryListCommand(int cmd) {
        GCHandle h = GCHandle.Alloc(cmd, GCHandleType.Pinned);
        try   { return NtSetSystemInformation(0x50, h.AddrOfPinnedObject(), sizeof(int)); }
        finally { h.Free(); }
    }

    // cmd=1: esvazia working sets do kernel
    public static uint EmptyKernelWorkingSets() {
        if (!SetPrivilege("SeProfileSingleProcessPrivilege")) return uint.MaxValue;
        return MemoryListCommand(1);
    }

    // cmd=2: transfere páginas modificadas para o pagefile, liberando RAM física
    public static uint FlushModifiedList() {
        if (!SetPrivilege("SeProfileSingleProcessPrivilege")) return uint.MaxValue;
        return MemoryListCommand(2);
    }

    // cmd=3: purga a standby list completa (páginas prontas para reutilização)
    public static uint PurgeStandbyList() {
        if (!SetPrivilege("SeProfileSingleProcessPrivilege")) return uint.MaxValue;
        return MemoryListCommand(3);
    }

    // cmd=4: purga apenas a standby list de baixa prioridade
    public static uint PurgeLowPriorityStandbyList() {
        if (!SetPrivilege("SeProfileSingleProcessPrivilege")) return uint.MaxValue;
        return MemoryListCommand(4);
    }

    public static uint ClearFileSystemCache() {
        if (!SetPrivilege("SeIncreaseQuotaPrivilege")) return uint.MaxValue;
        bool is64 = IntPtr.Size == 8;
        GCHandle h;
        int size;

        if (is64) {
            SYSTEM_CACHE_INFORMATION_64 info = new SYSTEM_CACHE_INFORMATION_64();
            info.MinimumWorkingSet = -1L;
            info.MaximumWorkingSet = -1L;
            size = Marshal.SizeOf(typeof(SYSTEM_CACHE_INFORMATION_64));
            h = GCHandle.Alloc(info, GCHandleType.Pinned);
        } else {
            SYSTEM_CACHE_INFORMATION info = new SYSTEM_CACHE_INFORMATION();
            info.MinimumWorkingSet = uint.MaxValue;
            info.MaximumWorkingSet = uint.MaxValue;
            size = Marshal.SizeOf(typeof(SYSTEM_CACHE_INFORMATION));
            h = GCHandle.Alloc(info, GCHandleType.Pinned);
        }

        try   { return NtSetSystemInformation(0x15, h.AddrOfPinnedObject(), size); }
        finally { h.Free(); }
    }

    // Combina páginas físicas idênticas (deduplicação — usado por otimizadores de jogos)
    public static uint CombinePhysicalMemory() {
        int dummy = 0;
        GCHandle h = GCHandle.Alloc(dummy, GCHandleType.Pinned);
        try   { return NtSetSystemInformation(0x60, h.AddrOfPinnedObject(), sizeof(int)); }
        finally { h.Free(); }
    }
}
"@ -Language CSharp -ErrorAction Stop
        } catch {
            $result.ErrorOccurred = $true
            $result.Message = "Falha compilando módulo C#: $_"
            Write-Log $result.Message 'e'
            return $result
        }
    }

    try {
        [System.GC]::Collect()
        $ramBefore = [NativeRamTools]::GetAvailablePhysicalMemory()

        $counts = [NativeRamTools]::EmptyAllWorkingSets()
        Write-Log "Working sets (user-mode): $($counts[0]) processos | $($counts[1]) protegidos" 'i'

        $r = [NativeRamTools]::EmptyKernelWorkingSets()
        if ($r -eq 0) { Write-Log 'Working sets (kernel) esvaziados' 'i' }

        $r = [NativeRamTools]::FlushModifiedList()
        if ($r -eq 0) { Write-Log 'Modified list transferida para pagefile' 'i' }

        $r = [NativeRamTools]::PurgeStandbyList()
        if ($r -eq 0) { Write-Log 'Standby list purgada (completa)' 'i' }

        $r = [NativeRamTools]::PurgeLowPriorityStandbyList()
        if ($r -eq 0) { Write-Log 'Standby list purgada (baixa prioridade)' 'i' }

        $r = [NativeRamTools]::ClearFileSystemCache()
        if ($r -eq 0) { Write-Log 'File system cache invalidado' 'i' }

        $r = [NativeRamTools]::CombinePhysicalMemory()
        if ($r -eq 0) { Write-Log 'Páginas físicas combinadas (dedup)' 'i' }

        Start-Sleep -Milliseconds 800
        $ramAfter = [NativeRamTools]::GetAvailablePhysicalMemory()

        $result.TotalFreedBytes = [Math]::Max(0, $ramAfter - $ramBefore)
        $result.Executed = $true
        $result.Success  = $true
        $result.Message  = "RAM recuperada: $(Format-Size -Bytes $result.TotalFreedBytes)"
        Write-Log $result.Message 'o'
    } catch {
        $result.ErrorOccurred = $true
        $result.Message = "Erro RAM: $_"
        Write-Log $result.Message 'e'
    }

    return $result
}

function Invoke-RamMapCleanup {
    $result = [PSCustomObject]@{
        Success = $false; Executed = $false; TotalFreedBytes = 0
        ErrorOccurred = $false; Message = ''
    }

    if (-not (Get-IsAdmin)) { return $result }

    if ([Environment]::Is64BitOperatingSystem) {
        $url = 'https://live.sysinternals.com/RAMMap64.exe'
        $exe = 'RAMMap64.exe'
    } else {
        $url = 'https://live.sysinternals.com/RAMMap.exe'
        $exe = 'RAMMap.exe'
    }
    $tempPath = "$env:TEMP\$exe"

    try {
        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
        Write-Log "Baixando $exe (fallback)" 'i'

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tempPath -UseBasicParsing -ErrorAction Stop
        Unblock-File -Path $tempPath -ErrorAction SilentlyContinue

        [System.GC]::Collect()
        $ramBefore = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024

        foreach ($flag in '-Ew', '-Es', '-Et') {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName        = $tempPath
            $psi.Arguments       = "$flag -AcceptEula"
            $psi.WindowStyle     = 'Hidden'
            $psi.UseShellExecute = $true
            $psi.Verb            = 'runas'
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit()
        }

        Start-Sleep -Milliseconds 500
        $ramAfter = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024

        $result.TotalFreedBytes = [Math]::Max(0, $ramAfter - $ramBefore)
        $result.Executed = $true
        $result.Success  = $true
        $result.Message  = "RAMMap recuperou: $(Format-Size -Bytes $result.TotalFreedBytes)"
        Write-Log $result.Message 'o'
    } catch {
        $result.ErrorOccurred = $true
        $result.Message = "Erro RAMMap: $_"
        Write-Log $result.Message 'e'
    } finally {
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

# ===== MAIN =====

Write-Log '===== full.ps1 iniciado =====' 'i'
$start = Get-Date

$isAdmin = Invoke-SelfElevation
if ($isAdmin) { Write-Log 'Modo: ADMIN (otimização completa)' 'o' } else { Write-Log 'Modo: USUÁRIO LIMITADO (RAM será pulada)' 'w' }

Close-Apps
Invoke-ThumbnailCacheReset
Invoke-StoreCacheReset
Invoke-DnsCleanup
$sys = Invoke-SystemCleanup
$brw = Invoke-BrowserCleanup

$ramFreed = 0
if ($isAdmin) {
    Invoke-UltimatePerformance
    $ram = Invoke-RamCleanup
    if ($ram.ErrorOccurred) {
        Write-Log 'Falha na limpeza nativa de RAM. Tentando fallback RAMMap...' 'w'
        $ram = Invoke-RamMapCleanup
    }
    $ramFreed = $ram.TotalFreedBytes
}

$totalDisk = $sys.TotalFreedBytes + $brw.TotalFreedBytes
$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
Write-Log "Disco liberado: $(Format-Size -Bytes $totalDisk)" 'o'
Write-Log "RAM liberada: $(Format-Size -Bytes $ramFreed)" 'o'
Write-Log "Tempo total: ${elapsed}s" 'i'
Write-Log '===== full.ps1 finalizado =====' 'i'
