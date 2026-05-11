$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Set-PowerShellWindowState {
    param(
        [ValidateSet('Minimize', 'Restore')]
        [string]$State
    )
    try {
        $code = @"
using System;
using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    public static void SetState(string state) {
        IntPtr hWnd = GetConsoleWindow();
        if (hWnd != IntPtr.Zero) {
            // 6 = SW_MINIMIZE, 9 = SW_RESTORE
            int cmd = (state == "Minimize") ? 6 : 9;
            ShowWindow(hWnd, cmd);
        }
    }
}
"@
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction SilentlyContinue
        [WinAPI]::SetState($State)
    } catch {
        # Ignore
    }
}

Set-PowerShellWindowState -State "Minimize"

function Get-SystemContext {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]$identity
    $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

    try {
        $sysInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $isEnterprise = $sysInfo.PartOfDomain
    } catch {
        $isEnterprise = $false
    }

    return [PSCustomObject]@{
        IsAdmin      = $isAdmin
        IsEnterprise = $isEnterprise
        IsPersonal   = -not $isEnterprise
        UserName     = $identity.Name
        MachineName  = $env:COMPUTERNAME
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Message,
        [Parameter(Position=1)]
        [ValidateSet("i", "w", "e", "o", "j", IgnoreCase=$true)]
        [string]$Level = "i"
    )

    switch ($Level) {
        "i" { $color = "Cyan";       $tag = " [i] " }
        "w" { $color = "Yellow";     $tag = " [!] " }
        "e" { $color = "Red";        $tag = " [X] " }
        "o" { $color = "Green";      $tag = " [v] " }
        "j" { $color = "Magenta";    $tag = " [»] " }
    }
    Write-Host "$tag $Message" -ForegroundColor $color
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -gt 0) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "0 Bytes" }
}

function Request-AdminPrivileges {
    $ctx = Get-SystemContext

    if ($ctx.IsAdmin) {
        Write-Log "Privilégios de administrador confirmados." "o"
        return $true
    }

    if ($ctx.IsPersonal) {
        Write-Log "Elevação de privilégios necessária." "i"
        try {
            $elevation = Start-Process powershell.exe `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
                -Verb RunAs `
                -ErrorAction Stop `
                -PassThru
            
            if ($elevation) {
                Write-Log "Elevação solicitada. PID: $($elevation.Id)" "o"
                Exit
            }
        } catch {
            Write-Log "Elevação cancelada ou falhou." "e"
            Write-Log "Executando em modo usuário." "w"
            Start-Sleep -Seconds 2
        }
    } else {
        Write-Log "Ambiente Corporativo detectado. Elevação bloqueada." "w"
        Write-Log "Executando em modo Usuário." "i"
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-RamCleanup {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        Success         = $false
        Executed        = $false
        TotalFreedBytes = 0
        DurationSeconds = 0
        ErrorOccurred   = $false
        Message         = ""
    }

    $executionStart = Get-Date

    $currentPrincipal = [System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $result.Message = "Requer privilégios elevados."
        Write-Log "Limpeza de RAM ignorada (Requer Admin)." "w"
        return $result
    }

    Write-Log "Iniciando protocolo de otimização agressiva de memória" "i"

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
            $result.Message = "Falha crítica na compilação: $_"
            Write-Log $result.Message "e"
            return $result
        }
    }

    try {
        [System.GC]::Collect()
        $ramBefore = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024

        Write-Log "Comprimindo Working Sets (Processos)" "i"
        $counts = [NativeRamTools]::EmptyAllWorkingSets()
        Write-Log "Processos Otimizados: $($counts[0]) | Protegidos: $($counts[1])" "i"

        $r = [NativeRamTools]::EmptyWorkingSetsKernel()
        if ($r -ne 0 -and $r -ne [uint32]::MaxValue) { 
            Write-Log "Aviso no Kernel Working Sets: 0x$($r.ToString('X'))" "w" 
        }

        $r = [NativeRamTools]::ClearFileSystemCache()
        if ($r -eq 0) { Write-Log "File System Cache invalidado." "i" }

        $r = [NativeRamTools]::PurgeStandbyList()
        if ($r -eq 0) { Write-Log "Standby List purgada." "i" }

        Start-Sleep -Milliseconds 500
        $ramAfter = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024

        $result.TotalFreedBytes = [Math]::Max(0, $ramAfter - $ramBefore)
        $result.Executed = $true
        $result.Success = $true
        $fmt = Format-Size -Bytes $result.TotalFreedBytes
        $result.Message = "Otimização concluída. RAM Recuperada: $fmt"

        if ($result.TotalFreedBytes -gt 0) {
            Write-Log $result.Message "o"
        } else {
            Write-Log "Memória remapeada com sucesso (Sem ganho livre imediato)." "o"
        }
    } catch {
        $result.ErrorOccurred = $true
        $result.Message = "Erro durante execução: $_"
        Write-Log $result.Message "e"
    } finally {
        $result.DurationSeconds = ((Get-Date) - $executionStart).TotalSeconds
    }

    return $result
}

$ctx = Get-SystemContext

Request-AdminPrivileges | Out-Null

$ramResult = Invoke-RamCleanup

$totalBytes = $ramResult.TotalFreedBytes
$fmtTotal = Format-Size -Bytes $totalBytes

if ($ctx.IsAdmin -and $ramResult.Success) {
    Write-Log "OTIMIZAÇÃO COMPLETA FINALIZADA" "o"
    Write-Log "RAM liberada: $fmtTotal" "i"
} else {
    Write-Log "OPERAÇÃO PARCIAL OU FALHOU" "w"
    if (-not $ctx.IsAdmin) { Write-Log "Motivo: Sem privilégios administrativos" "e" }
    if ($ramResult.ErrorOccurred) { Write-Log "Motivo: $($ramResult.Message)" "e" }
}