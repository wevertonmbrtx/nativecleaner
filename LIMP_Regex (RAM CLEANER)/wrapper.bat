@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
mode con:cols=55 lines=44
cls

:: X OPTIMIZER - BOOTSTRAPPER
:: Descrição:   Wrapper híbrido que executa um payload PowerShell embutido
::              para limpeza de sistema em nível de usuário/admin. 
:: Autor: Code4x (wevertonmbrtx)

:: Configuração de Ambiente
set "SCRIPT_PATH=%~f0"
set "PS_PAYLOAD=%TEMP%\XnoPayload_%RANDOM%_%TIME:~6,2%.ps1"

echo.
echo =======================================================
echo          [X OPTIMIZER] Inicializando ambiente
echo =======================================================
echo.
echo  [i] Extraindo núcleo de processamento...
echo.

powershell -NoProfile -Command ^
    "$ErrorActionPreference = 'Stop';" ^
    "$found = $false;" ^
    "$content = Get-Content -LiteralPath $env:SCRIPT_PATH -Encoding UTF8;" ^
    "$payload = foreach ($line in $content) {" ^
    "    if ($found) { $line } " ^
    "    elseif ($line -eq ':__POWERSHELL_START__') { $found = $true }" ^
    "};" ^
    "Set-Content -Path $env:PS_PAYLOAD -Value $payload -Encoding UTF8 -Force;"

:: Verificação de Integridade
if %ERRORLEVEL% NEQ 0 (
    echo  [X] Falha ao extrair o script PowerShell.
    echo Verifique permissões de escrita em: %TEMP%
    echo.
    pause
    exit /b 1
)

if not exist "%PS_PAYLOAD%" (
    echo  [X] Arquivo de payload não encontrado.
    echo.
    pause
    exit /b 1
)

:: Oculta o payload
attrib +s +h +r "%PS_PAYLOAD%"

echo  [i] Executando módulos de limpeza
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_PAYLOAD%"
set "EXIT_CODE=%ERRORLEVEL%"
timeout /t 1 /nobreak >nul

:: Remoção
setlocal enabledelayedexpansion
set "maxRetries=20"
set "retryCount=0"

:deleteRetry
if exist "%PS_PAYLOAD%" (
    if !retryCount! lss !maxRetries! (
        attrib -s -h -r "%PS_PAYLOAD%" >nul 2>&1
        timeout /t 1 /nobreak >nul
        del /f /q "%PS_PAYLOAD%" >nul 2>&1
        
        if exist "%PS_PAYLOAD%" (
            timeout /t 2 /nobreak >nul
            set /a "retryCount=!retryCount!+1"
            goto deleteRetry
        ) else (
            echo.
            echo  [i] O arquivo foi deletado com sucesso.
        )
    ) else (
        echo.
        echo  [X] O arquivo não pode ser deletado.
    )
)

echo.
echo  [i] Processo batch finalizado.
echo.
timeout /t 1 /nobreak >nul
cls
exit /b %EXIT_CODE%

:: ================================
::  PAYLOAD POWERSHELL
:: ================================
:__POWERSHELL_START__
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Set-ConsoleWindow {
    param(
        [Parameter(Mandatory=$false)]
        [ValidateSet('Minimize', 'Restore')]
        [string]$State,

        [Parameter(Mandatory=$false)]
        [switch]$Resize,

        [int]$Width = 55,
        [int]$Height = 44
    )

    # 1. Lógica de Redimensionamento
    if ($Resize -and $Host.Name -eq 'ConsoleHost') {
        try {
            $rawUI = $Host.UI.RawUI
            $maxPhys = $rawUI.MaxPhysicalWindowSize
            
            $w = [Math]::Min($Width, $maxPhys.Width)
            $h = [Math]::Min($Height, $maxPhys.Height)
            
            $targetSize = $rawUI.WindowSize
            $targetSize.Width = $w
            $targetSize.Height = $h
            
            # Garante que o Buffer seja grande o suficiente
            $buf = $rawUI.BufferSize
            if ($buf.Width -lt $w) { $buf.Width = $w }
            if ($buf.Height -lt $h) { $buf.Height = $h }
            $rawUI.BufferSize = $buf
            
            $rawUI.WindowSize = $targetSize
            $rawUI.BufferSize = $targetSize
        } catch {
            # Ignorar erros de redimensionamento
        }
    }

    # 2. Lógica de Estado da Janela (Minimizar/Restaurar)
    if ($PSBoundParameters.ContainsKey('State')) {
        try {
            # Verifica se o tipo já existe para evitar erros em chamadas subsequentes
            if (-not ('WinAPI' -as [type])) {
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
            }
            [WinAPI]::SetState($State)
        } catch {
            # Ignore
        }
    }
}

function Get-SystemContext {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]$identity
    
    # Detecção de Admin via Token do Kernel
    $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

    # Detecção de Domínio (Empresa vs Pessoal)
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

    $timestamp = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
    
    # Definição de Cores e Tags
    switch ($Level) {
        "i" { $color = "Cyan";       $tag = " [i] " }
        "w" { $color = "Yellow";     $tag = " [!] " }
        "e" { $color = "Red";        $tag = " [X] " }
        "o" { $color = "Green";      $tag = " [v] " }
        "j" { $color = "Magenta";    $tag = " [»] " }
    }

    # Saída Visual
    Write-Host "$tag $Message" -ForegroundColor $color

    # Saída em Arquivo Log
    if ($script:LogFile -and (Test-Path -Path (Split-Path $script:LogFile -Parent) -IsValid)) {
        $logLine = "[$timestamp] $tag $Message"
        Add-Content -LiteralPath $script:LogFile -Value $logLine -ErrorAction SilentlyContinue
    }
}

function Get-DirSize {
    param([string]$Path)
    
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        return $fso.GetFolder($Path).Size
    } catch {
        return 0
    }
}

function Format-Size {
    param([double]$Bytes)

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    } elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    } elseif ($Bytes -gt 0) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    } else {
        return "0 Bytes"
    }
}

function Close-Apps {
    Write-Log "Encerrando navegadores e aplicativos abertos..." "i"
    $targetApps = @("chrome", "msedge", "msedgewebview", "msedgewebview2", "opera", "brave", "firefox", "discord", "teams", "ms-teams", "code", "blitz")
    $anyClosed = $false
    
    foreach ($procName in $targetApps) {
        $processes = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($processes) {
            $processes | Stop-Process -Force -ErrorAction SilentlyContinue
            $anyClosed = $true
            Write-Log "Encerrando processos: $procName" "w"
        }
    }
    
    if ($anyClosed) { 
        Write-Log "Aplicativos encerrados para liberação de arquivos." "o"
    }
}

function Invoke-DnsCleanup {
    [CmdletBinding()]
    param()

    Write-Log "Limpeza de cache DNS iniciada." "i"

    try {
        if (Get-Command "Clear-DnsClientCache" -ErrorAction SilentlyContinue) {
            Clear-DnsClientCache -ErrorAction Stop
        }
        else {
            $process = Start-Process ipconfig -ArgumentList "/flushdns" -NoNewWindow -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "ipconfig retornou erro $($process.ExitCode)" }
        }

        Write-Log "Cache DNS limpo com sucesso." "o"
        return $true
    }
    catch {
        Write-Log "Falha ao limpar DNS: $_" "e"
        return $false
    }
}

function Invoke-StoreCacheReset {
    Write-Log "Resetando cache da Microsoft Store" "i"
    try {
        # Executa wsreset em Job separado para evitar travamento do script principal
        $job = Start-Job { Start-Process "wsreset.exe" -WindowStyle Hidden -Wait }
        
        # Timeout de segurança (15 segundos)
        if (-not (Wait-Job $job -Timeout 15)) {
            Stop-Job $job
            Stop-Process -Name "wsreset" -Force -ErrorAction SilentlyContinue
            Write-Log "Cache da Microsoft Store resetado (Forçado após timeout)." "o"
        } else {
            Remove-Job $job -Force
            Stop-Process -Name "WinStore.App" -Force -ErrorAction SilentlyContinue
            Write-Log "Cache da Microsoft Store resetado." "o"
        }
    } catch {
        Write-Log "Falha ao resetar MS Store: $_" "e"
    }
}

function Request-AdminPrivileges {
    param(
        [string]$ElevatedCopyMarker = "$env:TEMP\XnoPayload_Elevated_$RANDOM.ps1"
    )

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

    # Já está elevado
    if ($principal.IsInRole($adminRole)) {
        Write-Log "Privilégios de administrador confirmados." "o"
        
        # Limpa cópia elevada anterior se existir
        if (Test-Path -LiteralPath $ElevatedCopyMarker -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $ElevatedCopyMarker -Force -ErrorAction SilentlyContinue
        }
        return $true
    }

    # Não está elevado - tenta elevação
    Write-Log "Elevação de privilégios necessária." "i"

    # Valida caminho do script atual
    $selfPath = $PSCommandPath
    if (-not $selfPath -or -not (Test-Path -LiteralPath $selfPath)) {
        Write-Log "Caminho do script inválido. Elevação abortada." "e"
        return $false
    }

    # Prepara argumentos com escape correto para caminhos com espaços
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`""
    
    # Copia script para local temporário (evita lock do arquivo original)
    try {
        Copy-Item -LiteralPath $selfPath -Destination $ElevatedCopyMarker -Force -ErrorAction Stop
    } catch {
        Write-Log "Falha ao copiar script para elevação: $_" "e"
        return $false
    }

    # Configura elevação via ProcessStartInfo (mais confiável que Start-Process)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName         = "powershell.exe"
        $psi.Arguments        = $argList
        $psi.Verb             = "runas"
        $psi.UseShellExecute  = $true
        $psi.WorkingDirectory = Split-Path -Parent $selfPath
        
        $process = [System.Diagnostics.Process]::Start($psi)
        
        if ($null -eq $process) { 
            throw "Processo não iniciado." 
        }

        Write-Log "Elevação solicitada. PID: $($process.Id)" "o"
        Write-Log "Aguardando finalização do processo elevado..." "i"
        
        $process.WaitForExit()
        
        Remove-Item -LiteralPath $ElevatedCopyMarker -Force -ErrorAction SilentlyContinue
        
        # Encerra instância atual (não elevada)
        exit $process.ExitCode
        
    } catch {
        Write-Log "Falha na elevação" "e"
        
        # Limpeza em caso de falha
        Remove-Item -LiteralPath $ElevatedCopyMarker -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-SystemCleanup {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        Success           = $true
        TotalFreedBytes   = 0
        ItemsCleaned      = 0
        ItemsFailed       = 0
        ItemsSkipped      = 0
        TargetsFound      = 0
        DurationSeconds   = 0
        CompletedItems    = [System.Collections.Generic.List[string]]::new()
        FailedItems       = [System.Collections.Generic.List[string]]::new()
        ErrorOccurred     = $false
    }

    $executionStart = Get-Date
    Write-Log "Iniciando limpeza de sistema e aplicativos." "i"

    # ALVOS
    
    # Variáveis de Ambiente
    $roaming  = $env:APPDATA
    $local    = $env:LOCALAPPDATA
    $localLow = "$env:USERPROFILE\AppData\LocalLow"
    $win      = $env:windir
    $temp     = $env:TEMP

    $targets = @()

    # Função Helper Interna para montar objetos de limpeza
    function New-Target ($Path, $Name) { return [PSCustomObject]@{ Path = $Path; Name = $Name } }

    # Aplicações Electron e Similares (Cache Padrão)
    $electronApps = @(
        @{ Name = "Discord"; Path = "$roaming\discord" },
        @{ Name = "VSCode";  Path = "$roaming\Code" },
        @{ Name = "Teams";   Path = "$roaming\Microsoft\Teams" },
        @{ Name = "Blitz";   Path = "$roaming\Blitz" }
    )
    $electronFolders = @('Cache', 'Code Cache', 'GPUCache', 'gpu_logs', 'DawnGraphiteCache', 'DawnWebGPUCache')

    foreach ($app in $electronApps) {
        foreach ($sub in $electronFolders) {
            $targets += New-Target -Path "$($app.Path)\$sub" -Name "$($app.Name) $sub"
        }
    }

    # Caches Específicos do Windows e IE
    $winSubPaths = @(
        "Caches", "History\low", "IECompatCache", "IECompatUaCache", 
        "IEDownloadHistory", "INetCache", "Temporary Internet Files", 
        "WebCache", "ActionCenterCache", "AppCache",
        "WER\ReportQueue", "WER\ReportArchive", "WER\Temp"
    )
    if ((Get-SystemContext).IsAdmin) {
        foreach ($p in $winSubPaths) {
            $targets += New-Target -Path "$win\$p" -Name "Windows $p"
        }
    }

    # Caches Microsoft Local
    $msPaths = @(
        "GraphicsCache", "FontCache", "IdentityCache", "Package Cache", 
        "Windows Defender\Cache", "Windows Search", "OneDrive\Cache", "OneDrive\logs"
    )
    foreach ($p in $msPaths) {
        $targets += New-Target -Path "$local\Microsoft\$p" -Name "Microsoft $p"
    }

    ## Jogos (Riot)
    #$riotTitles = @("Riot Client", "League of Legends", "VALORANT")
    #foreach ($title in $riotTitles) {
    #    $targets += New-Target -Path "$local\Riot Games\$title" -Name "$title Temp"
    #}

    # Pastas Temporárias Globais e Diversos
    $targets += New-Target -Path "$temp" -Name "User Temp"
    $targets += New-Target -Path "$localLow\Temp" -Name "LocalLow Temp"
    $targets += New-Target -Path "$local\SquirrelTemp" -Name "Squirrel Temp"
    if ((Get-SystemContext).IsAdmin) {
        $targets += New-Target -Path "$env:SystemRoot\Prefetch" -Name "Windows Prefetch"
    }
    $targets += New-Target -Path "$local\Microsoft\Outlook\RoamCache" -Name "Outlook RoamCache"
    $targets += New-Target -Path "$local\Microsoft\Teams\cache" -Name "Teams Local Cache"

    # EXECUÇÃO

    foreach ($item in $targets) {
        if (-not (Test-Path -LiteralPath $item.Path)) { continue }
        
        $result.TargetsFound++

        try {
            # Medição Antes
            $sizeBefore = Get-DirSize -Path $item.Path
            
            if ($sizeBefore -gt 0) {
                # Limpeza (Silenciosa)
                Get-ChildItem -LiteralPath $item.Path -Recurse -Force -ErrorAction SilentlyContinue | 
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                
                # Medição Depois
                $sizeAfter = Get-DirSize -Path $item.Path
                $freed = $sizeBefore - $sizeAfter

                if ($freed -gt 0) {
                    $result.TotalFreedBytes += $freed
                    $result.ItemsCleaned++
                    
                    # Registro de sucesso
                    $fmt = Format-Size -Bytes $freed
                    Write-Log "$($item.Name) limpo. Liberado: $fmt" "o"
                    [void]$result.CompletedItems.Add("$($item.Name)|$freed")
                } else {
                    $result.ItemsSkipped++
                }
            } else {
                $result.ItemsSkipped++
            }
        } catch {
            $result.ErrorOccurred = $true
            $result.ItemsFailed++
            [void]$result.FailedItems.Add("$($item.Name)|$_")
            Write-Log "Falha ao acessar $($item.Name)" "w"
        }
    }

    # Limpeza Final (Lixeira)
    try {
        $recyclePath = "$env:SystemDrive\`$Recycle.Bin"
        $recycleBefore = Get-DirSize -Path $recyclePath
        
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        
        if ($recycleBefore -gt 0) {
            $result.TotalFreedBytes += $recycleBefore
            $fmtRecycle = Format-Size -Bytes $recycleBefore
            Write-Log "Lixeira esvaziada. Liberado: $fmtRecycle" "o"
        }
    } catch {
        # Ignorar erros
    }

    $result.DurationSeconds = ((Get-Date) - $executionStart).TotalSeconds
    
    if ($result.ErrorOccurred) { $result.Success = $false }

    return $result
}

function Invoke-BrowserCleanup {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        Success           = $true
        TotalFreedBytes   = 0
        ItemsCleaned      = 0
        ItemsFailed       = 0
        ItemsSkipped      = 0
        BrowsersFound     = 0
        BrowsersCleaned   = 0
        DurationSeconds   = 0
        CompletedItems    = [System.Collections.Generic.List[string]]::new()
        FailedItems       = [System.Collections.Generic.List[string]]::new()
        ErrorOccurred     = $false
    }

    $executionStart = Get-Date

    $browserConfig = @(
        @{ Name = "Google Chrome";  Path = "$env:LOCALAPPDATA\Google\Chrome\User Data";               Type = "chromium"; Targets = @("Cache", "Code Cache", "GPUCache", "ShaderCache", "Service Worker", "CacheStorage") },
        @{ Name = "Microsoft Edge"; Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data";              Type = "chromium"; Targets = @("Cache", "Code Cache", "GPUCache", "ShaderCache", "Service Worker", "CacheStorage") },
        @{ Name = "Edge WebView";   Path = "$env:LOCALAPPDATA\Microsoft\EdgeWebView\User Data";       Type = "chromium"; Targets = @("Cache", "Code Cache", "GPUCache", "ShaderCache") },
        @{ Name = "Brave";          Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; Type = "chromium"; Targets = @("Cache", "Code Cache", "GPUCache", "ShaderCache") },
        @{ Name = "Opera GX";       Path = "$env:LOCALAPPDATA\Opera Software\Opera GX Stable";        Type = "opera";    Targets = @("Cache", "System Cache", "GPUCache", "ShaderCache") },
        @{ Name = "Opera Stable";   Path = "$env:LOCALAPPDATA\Opera Software\Opera Stable";           Type = "opera";    Targets = @("Cache", "System Cache", "GPUCache", "ShaderCache") },
        @{ Name = "Firefox";        Path = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles";              Type = "firefox";  Targets = @("cache2", "startupCache", "thumbnails", "jumpListCache") }
    )

    Write-Log "Iniciando otimização de navegadores" "i"

    foreach ($browser in $browserConfig) {
        if (-not (Test-Path -LiteralPath $browser.Path)) { continue }

        $result.BrowsersFound++
        $browserFreed = 0
        $browserErrors = 0
        
        $profiles = @()
        $showProfileName = $false

        switch ($browser.Type) {
            "chromium" { 
            $profiles = Get-ChildItem -LiteralPath $browser.Path -Directory -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -notmatch '^(System Profile|Guest Profile|Crashpad|GrShaderCache|ShaderCache|WidevineCdm|pnacl|Subresource Filter|hyphen-data|ZxcvbnData|EVWhitelist|SSLErrorAssistant|SwReporter|BrowserMetrics|Safe Browsing|Floc|Segmentation Platform|OptimizationHints|OnDeviceHeadSuggest|PepperFlash|MEIPreload|CertificateTransparency|NativeMessagingHosts|extensions_crx_cache|FileTypePolicies|OriginTrials|PKIMetadata)$' }
            $showProfileName = $true 
            }
            "opera" { 
                $profiles = @(Get-Item -LiteralPath $browser.Path -ErrorAction SilentlyContinue) 
            }
            "firefox" { 
                $profiles = Get-ChildItem -LiteralPath $browser.Path -Directory -ErrorAction SilentlyContinue 
                $showProfileName = $true
            }
        }

        foreach ($p in $profiles) {
            foreach ($target in $browser.Targets) {
                $targetPath = Join-Path -Path $p.FullName -ChildPath $target
                
                if (Test-Path -LiteralPath $targetPath) {
                    $desc = "$($browser.Name) - $target"
                    if ($showProfileName) { $desc += " ($($p.Name))" }

                    try {
                        $sizeBefore = Get-DirSize -Path $targetPath
                        
                        if ($sizeBefore -gt 0) {
                            Get-ChildItem -LiteralPath $targetPath -Recurse -Force -ErrorAction SilentlyContinue | 
                                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                            
                            $sizeAfter = Get-DirSize -Path $targetPath
                            $freed = $sizeBefore - $sizeAfter

                            if ($freed -gt 0) {
                                $browserFreed += $freed
                                $result.ItemsCleaned++
                                [void]$result.CompletedItems.Add("$desc|$freed")
                            } else {
                                $result.ItemsSkipped++
                            }
                        } else {
                            $result.ItemsSkipped++
                        }
                    } catch {
                        $browserErrors++
                        $result.ItemsFailed++
                        $result.ErrorOccurred = $true
                        [void]$result.FailedItems.Add("$desc|$_")
                    }
                }
            }
        }

        $result.TotalFreedBytes += $browserFreed

        if ($browserFreed -gt 0) {
            $result.BrowsersCleaned++
            $fmt = Format-Size -Bytes $browserFreed
            Write-Log "$($browser.Name) otimizado. Liberado: $fmt" "o"
        } elseif ($browserErrors -gt 0) {
            Write-Log "Erros ao limpar $($browser.Name). Verifique logs." "e"
        }
    }

    $result.DurationSeconds = ((Get-Date) - $executionStart).TotalSeconds
    
    if ($result.ErrorOccurred) { $result.Success = $false }

    return $result
}

function Invoke-RamMapCleanup {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        Success           = $false
        Executed          = $false
        TotalFreedBytes   = 0
        DurationSeconds   = 0
        ErrorOccurred     = $false
        Message           = ""
    }

    $executionStart = Get-Date

    # Verificação de Admin
    if (-not (Get-SystemContext).IsAdmin) {
        $result.Message = "Requer privilégios elevados."
        Write-Log "Limpeza RAMMap ignorada (Requer Admin)." "w"
        return $result
    }

    Write-Log "Iniciando protocolo RAMMap (Download & Run)" "i"

    # 2. Definição da URL (32 vs 64 bits) e Caminhos
    if ([Environment]::Is64BitOperatingSystem) {
        $url = "https://live.sysinternals.com/RAMMap64.exe"
        $exeName = "RAMMap64.exe"
    } else {
        $url = "https://live.sysinternals.com/RAMMap.exe"
        $exeName = "RAMMap.exe"
    }
    
    $tempPath = "$env:TEMP\$exeName"

    try {
        # Download

        # Verifica se já existe (de uma execução falha anterior) e deleta
        if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }

        Write-Log "Baixando $exeName da Microsoft" "i"
        
        # TLS 1.2 é necessário para downloads modernos da Microsoft
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tempPath -UseBasicParsing -ErrorAction Stop
        
        # Desbloqueia o arquivo (SmartScreen pode marcar como perigoso por vir da internet)
        Unblock-File -Path $tempPath -ErrorAction SilentlyContinue

        # Medição Inicial
        [System.GC]::Collect()
        $ramBefore = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024
        
        $commands = @(
            @{ Flag = "-Ew"; Desc = "Esvaziando Working Sets" },
            @{ Flag = "-Es"; Desc = "Esvaziando System Sets" },
            @{ Flag = "-Et"; Desc = "Purgando Standby List" }
        )

        foreach ($cmd in $commands) {
            Write-Log "Executando: $($cmd.Desc)" "i"
            $pInfo = New-Object System.Diagnostics.ProcessStartInfo
            $pInfo.FileName = $tempPath
            $pInfo.Arguments = "$($cmd.Flag) -AcceptEula"
            $pInfo.WindowStyle = "Hidden"
            $pInfo.UseShellExecute = $true
            $pInfo.Verb = "runas"

            $proc = [System.Diagnostics.Process]::Start($pInfo)
            $proc.WaitForExit() # Espera terminar antes do próximo
        }

        # Medição Final
        Start-Sleep -Milliseconds 500
        $ramAfter = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024
        
        $result.TotalFreedBytes = [Math]::Max(0, $ramAfter - $ramBefore)
        $result.Executed        = $true
        $result.Success         = $true
        
        $fmt = Format-Size -Bytes $result.TotalFreedBytes
        $result.Message = "RAMMap finalizado. Recuperado: $fmt"

        if ($result.TotalFreedBytes -gt 0) {
            Write-Log $result.Message "o"
        } else {
            Write-Log "Memória remapeada com sucesso." "o"
        }

    } catch {
        $result.ErrorOccurred = $true
        $result.Message       = "Erro no processo RAMMap: $_"
        Write-Log $result.Message "e"
    } finally {
        # Remove o executável da pasta Temp, independente de sucesso ou falha
        if (Test-Path $tempPath) {
            try {
                Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
                # Write-Log "Lixo temporário removido." "i" # (Opcional, para não poluir o log)
            } catch {
                Write-Log "Não foi possível deletar $exeName (Pode estar em uso)." "w"
            }
        }
        $result.DurationSeconds = ((Get-Date) - $executionStart).TotalSeconds
    }

    return $result
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

    # Verificação de Admin
    if (-not (Get-SystemContext).IsAdmin) {
        $result.Message = "Requer privilégios elevados."
        Write-Log "Limpeza de RAM ignorada (Requer Admin)." "w"
        return $result
    }

    Write-Log "Iniciando protocolo de otimização agressiva de memória" "i"

    # Compilação Dinâmica de Ferramentas Nativas (C#)
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

    // Helper: Adquirir Privilégios
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

    // Fase 1: Resetar processos (Trim Working Set)
    public static int[] EmptyAllWorkingSets() {
        int trimmed = 0, skipped = 0;
        foreach (Process p in Process.GetProcesses()) {
            // Ignora System Idle (0) e System (4)
            if (p.Id == 0 || p.Id == 4) { skipped++; continue; }
            try {
                if (!p.HasExited) { EmptyWorkingSet(p.Handle); trimmed++; }
            } catch { skipped++; }
        }
        return new int[] { trimmed, skipped };
    }

    // Fase 2: Resetar Resetar processos via Kernel
    public static uint EmptyWorkingSetsKernel() {
        if (!SetPrivilege("SeProfileSingleProcessPrivilege")) return uint.MaxValue;
        int cmd = 2; // MemoryEmptyWorkingSets
        GCHandle h = GCHandle.Alloc(cmd, GCHandleType.Pinned);
        try   { return NtSetSystemInformation(0x50, h.AddrOfPinnedObject(), sizeof(int)); }
        finally { h.Free(); }
    }

    // Fase 3: Limpar File System Cache
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

    // Fase 4: Purgar Standby List
    public static uint PurgeStandbyList() {
        if (!SetPrivilege("SeProfileSingleProcessPrivilege")) return uint.MaxValue;
        int cmd = 4; // MemoryPurgeStandbyList
        GCHandle h = GCHandle.Alloc(cmd, GCHandleType.Pinned);
        try   { return NtSetSystemInformation(0x50, h.AddrOfPinnedObject(), sizeof(int)); }
        finally { h.Free(); }
    }
}
"@ -Language CSharp -ErrorAction Stop
        } catch {
            $result.ErrorOccurred = $true
            $result.Message       = "Falha crítica na compilação do módulo de memória: $_"
            Write-Log $result.Message "e"
            return $result
        }
    }

    try {
        # Medição Inicial (GC Coletado para precisão)
        [System.GC]::Collect()
        $ramBefore = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024

        # Fase 1: Resetar processos (Trim Working Set)
        Write-Log "Comprimindo Working Sets (Processos)" "i"
        $counts = [NativeRamTools]::EmptyAllWorkingSets()
        Write-Log "Processos Otimizados: $($counts[0]) | Protegidos: $($counts[1])" "i"

        # Fase 2: Resetar Resetar processos via Kernel
        $r = [NativeRamTools]::EmptyWorkingSetsKernel()
        if ($r -ne 0 -and $r -ne [uint32]::MaxValue) { 
            Write-Log "Aviso no Kernel Working Sets: 0x$($r.ToString('X'))" "w" 
        }

        # Fase 3: Limpar File System Cache
        $r = [NativeRamTools]::ClearFileSystemCache()
        if ($r -eq 0) { 
            Write-Log "File System Cache invalidado." "i" 
        }

        # Fase 4: Purgar Standby List
        $r = [NativeRamTools]::PurgeStandbyList()
        if ($r -eq 0) { 
            Write-Log "Standby List purgada." "i" 
        }

        # Medição Final
        Start-Sleep -Milliseconds 500
        $ramAfter = (Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory * 1024

        $result.TotalFreedBytes = [Math]::Max(0, $ramAfter - $ramBefore)
        $result.Executed        = $true
        $result.Success         = $true
        
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

function Wait-ProcessWithWindowRefresh {
    param(
        [Parameter(Mandatory=$true)]
        $Process,
        [Parameter(Mandatory=$false)]
        [string]$ProcessName = "Process",
        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 300
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Adiciona capacidade de manipular janelas se não existir
    if (-not ("Win32.WindowHelper" -as [type])) {
        $code = '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);'
        Add-Type -MemberDefinition $code -Name WindowHelper -Namespace Win32 -ErrorAction SilentlyContinue
    }
    
    while (-not $Process.HasExited) {
        if ($stopwatch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            Write-Log "Timeout aguardando $ProcessName após $TimeoutSeconds segundos" "w"
            try { $Process.Kill() } catch {}
            break
        }
        
        # Tenta trazer a janela para frente periodicamente para evitar congelamento
        if ($stopwatch.ElapsedMilliseconds % 2000 -lt 100) {
            try {
                $hwnd = $Process.MainWindowHandle
                if ($hwnd -and $hwnd -ne [IntPtr]::Zero) {
                    [Win32.WindowHelper]::SetForegroundWindow($hwnd) | Out-Null
                }
            } catch {}
        }
        
        Start-Sleep -Milliseconds 100
    }
    
    $stopwatch.Stop()
}

function Invoke-DiskCleanupDialog {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        Success           = $true
        TotalFreedBytes   = 0
        DurationSeconds   = 0
        ErrorOccurred     = $false
        Message           = ""
        UserCancelled     = $false
    }

    $executionStart = Get-Date

    # Identifica a letra do drive do sistema (Geralmente C)
    $systemDrive = $env:SystemDrive.Substring(0,1)

    if ((Get-SystemContext).IsAdmin) {
        Write-Log "Iniciando Limpeza de Disco Nativa (Modo Automático)" "i"
        
        try {
            # Medição Antes
            $driveInfoBefore = Get-PSDrive -Name $systemDrive
            $bytesBefore = $driveInfoBefore.Free

            # Configuração do Registro (SageRun:64)
            $cleanupItems = @(
                "Active Setup Temp Folders", "BranchCache", "Content Indexer Cleaner", 
                "D3D Shader Cache", "Delivery Optimization Files", "Device Driver Packages",
                "Diagnostic Data Viewer database files", "Downloaded Program Files", 
                "Feedback Hub Archive log files", "Internet Cache Files", "Language Pack", 
                "Memory Dump Files", "Offline Pages Files", "Old ChkDsk Files", 
                "Previous Installations", "Recycle Bin", "RetailDemo Offline Content", 
                "Setup Log Files", "System error memory dump files", "System error minidump files", 
                "Temporary Files", "Temporary Setup Files", "Thumbnail Cache", "Update Cleanup", 
                "Upgrade Discarded Files", "User file versions", "Windows Defender", 
                "Windows Error Reporting Archive Files", "Windows Error Reporting Files", 
                "Windows ESD installation files", "Windows Reset Log Files", 
                "Windows Upgrade Log Files"
            )

            # Define StateFlags0064 = 2 (Selecionado) para cada item
            foreach ($item in $cleanupItems) {
                $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\$item"
                if (Test-Path $regPath) {
                    Set-ItemProperty -Path $regPath -Name "StateFlags0064" -Type DWORD -Value 2 -ErrorAction SilentlyContinue
                }
            }

            # Execução Silenciosa
            Write-Log "Executando CleanMgr (Isso pode demorar)" "i"
            $process = Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:64" -PassThru -WindowStyle Hidden
            Wait-ProcessWithWindowRefresh -Process $process -ProcessName "cleanmgr" -TimeoutSeconds 600

            # Medição Depois
            $driveInfoAfter = Get-PSDrive -Name $systemDrive
            $bytesAfter = $driveInfoAfter.Free
            
            # Cálculo seguro (evita negativos se o disco for usado durante o processo)
            $freed = $bytesAfter - $bytesBefore
            if ($freed -lt 0) { $freed = 0 }

            if ($freed -gt 0) {
                $result.TotalFreedBytes = $freed
                $fmt = Format-Size -Bytes $freed
                Write-Log "Limpeza nativa concluída. Liberado: $fmt" "o"
            } else {
                Write-Log "Limpeza nativa concluída (Sem ganho significativo)." "o"
            }

        } catch {
            $result.ErrorOccurred = $true
            $result.Message = "Erro na automação do CleanMgr: $_"
            Write-Log $result.Message "e"
        }

    } else {
        # MODO INTERATIVO (SEM ADMIN)
        Write-Log "Modo Administrador não detectado" "w"

        # Carrega Assembly para MessageBox
        Add-Type -AssemblyName System.Windows.Forms

        $msgBody = "Rodando em modo usuário.`n`neseja abrir a Limpeza de Disco do Windows manualmente?`n(Você terá que selecionar os itens e clicar em OK)."
        $msgTitle = "Limpeza de Disco"
        $choice = [System.Windows.Forms.MessageBox]::Show($msgBody, $msgTitle, 'YesNo', 'Question')

        if ($choice -eq 'Yes') {
            try {
                # Medição Antes
                $driveInfoBefore = Get-PSDrive -Name $systemDrive
                $bytesBefore = $driveInfoBefore.Free

                Write-Log "Aguardando finalizar a limpeza na janela pop-up" "i"
                
                # Abre a janela e espera fechar
                $process = Start-Process "cleanmgr.exe" -ArgumentList "/d $systemDrive" -PassThru
                Wait-ProcessWithWindowRefresh -Process $process -ProcessName "cleanmgr" -TimeoutSeconds 600

                # Medição Depois
                $driveInfoAfter = Get-PSDrive -Name $systemDrive
                $bytesAfter = $driveInfoAfter.Free
                $freed = $bytesAfter - $bytesBefore
                if ($freed -lt 0) { $freed = 0 }

                $result.TotalFreedBytes = $freed
                $fmt = Format-Size -Bytes $freed
                Write-Log "Processo manual finalizado. Liberado: $fmt" "o"

            } catch {
                $result.ErrorOccurred = $true
                $result.Message = "Falha ao iniciar cleanmgr: $_"
                Write-Log $result.Message "e"
            }
        } else {
            $result.UserCancelled = $true
            Write-Log "Limpeza de disco pulada pelo usuário." "w"
        }
    }

    $result.DurationSeconds = ((Get-Date) - $executionStart).TotalSeconds
    return $result
}

function Invoke-ThumbnailCacheReset {
    Write-Log "Recriando cache de miniaturas" "i"
    try {
        $thumbDbPath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
        if (Test-Path -LiteralPath $thumbDbPath) {
            # Explorer precisa ser reiniciado para liberar os arquivos .db
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            
            $thumbFreed = 0
            Get-ChildItem -LiteralPath $thumbDbPath -Filter "*.db" -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $size = $_.Length / 1MB
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                    $thumbFreed += $size
                } catch {}
            }
            
            # Reinicia o Explorer se não voltou automaticamente
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
                Start-Process explorer.exe
            }
            Write-Log "Cache de ícones recriado" "o"
            if ($thumbFreed -gt 0) {
                $fmt = Format-Size -Bytes ($thumbFreed * 1MB)
                Write-Log "Cache de miniaturas limpo. Liberado: $fmt" "o"
            } else {
                Write-Log "Cache de miniaturas limpo (Sem ganho significativo)." "o"
            }
        }
    } catch {
        # Garantia de retorno do shell em caso de erro
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-Log "Erro ao limpar miniaturas: $_" "e"
    }
}

if ((Get-SystemContext).IsAdmin) {
    Write-Log "Modo: ADMINISTRADOR (Otimização Completa)" "o"
} elseif ((Get-SystemContext).IsPersonal) {
    Write-Log "Computador Pessoal detectado (Sem Domínio). Tentando elevação..." "i"
    $elevated = Request-AdminPrivileges
    if ($elevated) {
        exit
    } else {
        Write-Log "Elevação falhou ou foi negada. Continuando em modo limitado." "w"
        Write-Log "Modo: USUÁRIO LIMITADO. Otimização parcial em execução." "i"
    }
} elseif ((Get-SystemContext).IsCorporate) {
    Write-Log "Computador Corporativo detectado (Domínio). Elevação bloqueada." "w"
    Write-Log "Modo: USUÁRIO LIMITADO. Otimização parcial em execução." "i"
} else {
    Write-Log "Contexto do sistema desconhecido. Continuando com permissões atuais." "w"
    Write-Log "Modo: USUÁRIO LIMITADO. Otimização parcial em execução." "i"
}

Set-ConsoleWindow -Resize

Close-Apps

Invoke-ThumbnailCacheReset

Invoke-StoreCacheReset

$dnsCleanup = Invoke-DnsCleanup

$sysResult = Invoke-SystemCleanup

$browserResult = Invoke-BrowserCleanup

#$diskResult = Invoke-DiskCleanupDialog

# Garante que a variável exista com valores zerados caso a limpeza de disco esteja desativada
if (-not $diskResult) { $diskResult = [PSCustomObject]@{ TotalFreedBytes = 0; DurationSeconds = 0 } }

try {
    $ramResult = Invoke-RamCleanup
} catch {
    try {
        $ramResult = Invoke-RamMapCleanup
    } catch {
        Write-Log "Erro ao executar limpeza de RAM: $_" "e"
        $ramResult = [PSCustomObject]@{ TotalFreedBytes = 0; DurationSeconds = 0 }
    }
}

$totalBytes = $sysResult.TotalFreedBytes + $browserResult.TotalFreedBytes + $diskResult.TotalFreedBytes
$totalFreed = Format-Size -Bytes $totalBytes
$totalRamFreed = Format-Size -Bytes $ramResult.TotalFreedBytes
$totalTime = [math]::Round($sysResult.DurationSeconds + $browserResult.DurationSeconds + $diskResult.DurationSeconds + $ramResult.DurationSeconds, 2)

Write-Host "`n=======================================================" -ForegroundColor Cyan
if ((Get-SystemContext).IsAdmin) {
    Write-Log "OTIMIZAÇÃO COMPLETA FINALIZADA" "o"
    Write-Log "RAM Otimizada: $totalRamFreed" "i"
} else {
    Write-Log "OTIMIZAÇÃO PARCIAL FINALIZADA (Modo Usuário)" "w"
}
Write-Log "Tempo de execução: $totalTime segundos" "i"
Write-Log "Espaço Total Recuperado: $totalFreed" "i"
Write-Host "=======================================================" -ForegroundColor Cyan

Start-Sleep -Seconds 3
