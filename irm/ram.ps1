# ram.ps1 — Limpeza agressiva de RAM (Working Sets, Standby List, FS Cache) — requer admin
# Uso: irm bit.ly/wgitncr | iex
# Log: %TEMP%\ncr.log

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$script:SourceUrl = 'https://raw.githubusercontent.com/wevertonmbrtx/nativecleaner/refs/heads/main/irm/ram.ps1'
$script:LogFile   = "$env:TEMP\ncr.log"

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

    $tempScript = "$env:TEMP\nc_$(Get-Random).ps1"
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
using System.ComponentModel;

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

    public static uint EmptyWorkingSetsKernel() {
        if (!SetPrivilege("SeProfileSingleProcessPrivilege")) return uint.MaxValue;
        int cmd = 2;
        GCHandle h = GCHandle.Alloc(cmd, GCHandleType.Pinned);
        try   { return NtSetSystemInformation(0x50, h.AddrOfPinnedObject(), sizeof(int)); }
        finally { h.Free(); }
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

    public static uint PurgeStandbyList() {
        if (!SetPrivilege("SeProfileSingleProcessPrivilege")) return uint.MaxValue;
        int cmd = 4;
        GCHandle h = GCHandle.Alloc(cmd, GCHandleType.Pinned);
        try   { return NtSetSystemInformation(0x50, h.AddrOfPinnedObject(), sizeof(int)); }
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
        $ramBefore = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024

        Write-Log 'Comprimindo Working Sets (processos)' 'i'
        $counts = [NativeRamTools]::EmptyAllWorkingSets()
        Write-Log "Processos otimizados: $($counts[0]) | protegidos: $($counts[1])" 'i'

        $r = [NativeRamTools]::EmptyWorkingSetsKernel()
        if ($r -ne 0 -and $r -ne [uint32]::MaxValue) {
            Write-Log "Aviso Kernel WS: 0x$($r.ToString('X'))" 'w'
        }

        $r = [NativeRamTools]::ClearFileSystemCache()
        if ($r -eq 0) { Write-Log 'File System Cache invalidado' 'i' }

        $r = [NativeRamTools]::PurgeStandbyList()
        if ($r -eq 0) { Write-Log 'Standby List purgada' 'i' }

        Start-Sleep -Milliseconds 500
        $ramAfter = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024

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

Write-Log '===== ram.ps1 iniciado =====' 'i'
$start = Get-Date

if (-not (Invoke-SelfElevation)) {
    Write-Log 'Sem privilégios admin. RAM cleanup abortado.' 'e'
    exit 1
}

$ram = Invoke-RamCleanup
if ($ram.ErrorOccurred) {
    Write-Log 'Falha na limpeza nativa. Tentando fallback RAMMap...' 'w'
    $ram = Invoke-RamMapCleanup
}

$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
Write-Log "Total RAM: $(Format-Size -Bytes $ram.TotalFreedBytes) em ${elapsed}s" 'o'
Write-Log '===== ram.ps1 finalizado =====' 'i'
