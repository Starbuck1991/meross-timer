# apagado.ps1
# Script para apagar automáticamente el equipo tras un período de inactividad y bajo tráfico de red.
# Uso: .\apagado.ps1 [-ApiKey "Apollo1991!"] [-DebugMode]
# Versión: 1.1.0

# Definir parámetros y versión al inicio
param (
    [Parameter(Mandatory=$false)]
    [string]$ApiKey, # Clave API para Meross
    [Parameter(Mandatory=$false)]
    [switch]$DebugMode # Modo depuración para logs adicionales
)

$ScriptVersion = "1.1.0" # Número de versión del script

# Configurar codificación UTF-8 para caracteres especiales
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Cambiar página de códigos a UTF-8 si es posible
try { chcp 65001 | Out-Null } catch { }

# Configuración global
$IdleThresholdMinutes = 2  # Minutos de inactividad antes de apagar
$IdleThresholdSeconds = $IdleThresholdMinutes * 60
$NetworkIntervalMinutes = 2  # Intervalo para medir tráfico de red
$NetworkThresholdKB = 10000  # Umbral de tráfico de red en KB
$NetworkThresholdBytes = $NetworkThresholdKB * 1024  # Convertir KB a bytes
$ShutdownWarningSeconds = 30  # Segundos de aviso antes del apagado
$MaxLogSizeMB = 1  # Tamaño máximo de logs en MB
$MerossApiTimeoutSec = 60  # Timeout para API Meross en Schedule-KodiPlexShutdown
$MerossKeepAliveTimeoutSec = 15  # Timeout para solicitud keep-alive
$MerossMaxRetries = 3  # Reintentos para API Meross
$MaxApiKeyAttempts = 3  # Intentos para clave API en modo manual
$KodiPlexShutdownDelayMinutes = 1  # Retraso para apagado de KodiPlex (60 segundos)
$PCShutdownDelaySeconds = 0  # Apagado inmediato del PC

# Procesos críticos que impiden el apagado
$CriticalProcesses = @("Teams", "Zoom", "obs64", "StreamlabsOBS", "chrome", "firefox")

# Rutas de archivos (prefijo reg_ para agrupación)
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDirectory = $ScriptPath  # Directorio de logs (sinónimo de ScriptPath)
$LogFile = Join-Path $ScriptPath "reg_apagado.log"
$LastRunFile = Join-Path $ScriptPath "reg_ejecutado.log"
$NetworkHistoryFile = Join-Path $ScriptPath "reg_trafico_historial.log"
$LastCleanupFile = Join-Path $ScriptPath "reg_fecha_limpieza.log"
$ControlMerossPath = Join-Path $ScriptPath "control-meross.ps1"

# Búfer para logs en memoria
$LogBuffer = @()

# Definir tipo AutoShutdown_IdleUser protegido contra redefinición
if (-not ([System.Type]::GetType("AutoShutdown_IdleUser"))) {
    $TypeDefinition = @"
using System;
using System.Runtime.InteropServices;
public class AutoShutdown_IdleUser {
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref AutoShutdown_LastInputInfo plii);
    [DllImport("kernel32.dll")]
    public static extern uint GetTickCount();
}
public struct AutoShutdown_LastInputInfo {
    public uint cbSize;
    public uint dwTime;
}
"@
    try {
        Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
    }
    catch {
        Write-Log "ERROR: Fallo al definir tipo AutoShutdown_IdleUser: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

# Función para escribir logs en el búfer y la consola
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    $LogEntry = "[$Level] $Timestamp - $Message"
    $script:LogBuffer += $LogEntry
    Write-Host $LogEntry
}

# Función para escribir el búfer de logs al archivo
function Flush-LogBuffer {
    param ([string]$FilePath = $LogFile)
    $maxRetries = 3
    $retryCount = 0
    $success = $false
    
    # Añadir líneas en blanco al búfer si es el final de un registro
    if ($LogBuffer -like "*=== VERIFICACIÓN COMPLETADA ===*") {
        $script:LogBuffer += ""
        if ($DebugMode) {
            Write-Host "[DEBUG] $((Get-Date -Format 'dd/MM/yyyy HH:mm:ss')) - Añadidas dos líneas en blanco al búfer"
        }
    }
    
    while (-not $success -and $retryCount -lt $maxRetries) {
        try {
            $script:LogBuffer | Out-File -FilePath $FilePath -Encoding UTF8 -Append -ErrorAction Stop
            $success = $true
        }
        catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                Write-Host "Error escribiendo log en ${FilePath}: $($_.Exception.Message)"
            }
            else {
                Start-Sleep -Milliseconds (100 * $retryCount + (Get-Random -Minimum 0 -Maximum 50))
            }
        }
    }
}

# Función para escribir contenido en archivos con reintentos
function Add-ContentSafe {
    param (
        [string]$Path,
        [string]$Value
    )
    $maxRetries = 3
    $retryCount = 0
    
    while ($retryCount -lt $maxRetries) {
        try {
            Add-Content -Path $Path -Value $Value -Encoding UTF8 -ErrorAction Stop
            return $true
        }
        catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                Write-Log "Error escribiendo en ${Path}: $($_.Exception.Message)" "ERROR"
                return $false
            }
            Start-Sleep -Milliseconds (100 * $retryCount + (Get-Random -Minimum 0 -Maximum 50))
        }
    }
    return $false
}

# Función para escribir archivos completos con manejo de concurrencia
function Out-FileSafe {
    param (
        [string[]]$Content,
        [string]$FilePath
    )
    $maxRetries = 3
    $retryCount = 0
    
    Get-ChildItem -Path (Split-Path -Parent $FilePath) -Filter "*.tmp_*" | Remove-Item -Force -ErrorAction SilentlyContinue
    
    while ($retryCount -lt $maxRetries) {
        $tempFile = "${FilePath}.tmp_$(Get-Random)"
        try {
            $Content | Out-File -FilePath $tempFile -Encoding UTF8 -Force -ErrorAction Stop
            Move-Item -Path $tempFile -Destination $FilePath -Force -ErrorAction Stop
            return $true
        }
        catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                Write-Log "Error escribiendo en ${FilePath}: $($_.Exception.Message)" "ERROR"
                return $false
            }
            Start-Sleep -Milliseconds (200 * $retryCount + (Get-Random -Minimum 0 -Maximum 100))
        }
    }
    return $false
}

# Función para verificar si el tamaño de un log excede el límite
function Test-LogFileSize {
    param (
        [string]$FilePath,
        [double]$MaxSizeMB = $MaxLogSizeMB
    )
    if (-not (Test-Path $FilePath)) { return $false }
    
    try {
        $fileSizeMB = (Get-Item $FilePath -ErrorAction Stop).Length / 1MB
        return $fileSizeMB -gt $MaxSizeMB
    }
    catch {
        Write-Log "Error verificando tamaño de ${FilePath}: $($_.Exception.Message)" "WARN"
        return $false
    }
}

# Función para limpiar el log principal, manteniendo las últimas 48 horas
function Clean-MainLogFile {
    param ([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) { return }
    
    if (Test-LogFileSize -FilePath $FilePath) {
        try { 
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Archivo ${FilePath} limpiado por exceder tamaño"
        }
        catch { 
            Write-Log "Error limpiando ${FilePath}: $($_.Exception.Message)" "ERROR" 
        }
        return
    }
    
    try {
        $CutoffTime = (Get-Date).AddHours(-48)
        $KeptLines = @()
        $entryCount = 0
        $lastWasEmpty = $false
        
        $streamReader = [System.IO.StreamReader]::new($FilePath, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $streamReader.ReadLine())) {
                if ($line -eq "") {
                    if (-not $lastWasEmpty) {
                        $KeptLines += $line
                        $lastWasEmpty = $true
                    }
                    continue
                }
                $lastWasEmpty = $false
                if ($line -match '^\[.*?\]\s(\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2})\s-') {
                    try {
                        $lineTimestamp = [datetime]::ParseExact($Matches[1], "dd/MM/yyyy HH:mm:ss", $null)
                        if ($lineTimestamp -ge $CutoffTime) {
                            $KeptLines += $line
                            $entryCount++
                        }
                    }
                    catch { 
                        $KeptLines += $line
                        $entryCount++
                    }
                }
                else {
                    $KeptLines += $line
                    $entryCount++
                }
            }
        }
        finally { 
            $streamReader.Close()
            $streamReader.Dispose() 
        }
        
        if ($KeptLines.Count -gt 0) {
            if (Out-FileSafe -Content $KeptLines -FilePath $FilePath) {
                Write-Log "Log principal limpiado. Entradas mantenidas: $entryCount"
            }
        }
        else {
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Log principal limpiado completamente"
        }
    }
    catch { 
        Write-Log "Error limpiando log ${FilePath}: $($_.Exception.Message)" "ERROR" 
    }
}

# Función para limpiar el log de ejecuciones, manteniendo las últimas 48 horas
function Clean-ExecutionLogFile {
    param ([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) { return }
    
    if (Test-LogFileSize -FilePath $FilePath) {
        try { 
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Archivo ${FilePath} limpiado por exceder tamaño"
        }
        catch { 
            Write-Log "Error limpiando ${FilePath}: $($_.Exception.Message)" "ERROR" 
        }
        return
    }
    
    try {
        $CutoffTime = (Get-Date).AddHours(-48)
        $KeptLines = @()
        $entryCount = 0
        
        $streamReader = [System.IO.StreamReader]::new($FilePath, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $streamReader.ReadLine())) {
                if ($line -match '^(\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2})\s\|') {
                    try {
                        $lineTimestamp = [datetime]::ParseExact($Matches[1], "dd/MM/yyyy HH:mm:ss", $null)
                        if ($lineTimestamp -ge $CutoffTime) { 
                            $KeptLines += $line
                            $entryCount++ 
                        }
                    }
                    catch { 
                        $KeptLines += $line
                        $entryCount++ 
                    }
                }
            }
        }
        finally { 
            $streamReader.Close()
            $streamReader.Dispose() 
        }
        
        if ($KeptLines.Count -gt 0) {
            if (Out-FileSafe -Content $KeptLines -FilePath $FilePath) {
                Write-Log "Log de ejecuciones limpiado. Entradas mantenidas: $entryCount"
            }
        }
        else {
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Log de ejecuciones limpiado completamente"
        }
    }
    catch { 
        Write-Log "Error limpiando ${FilePath}: $($_.Exception.Message)" "ERROR" 
    }
}

# Función para limpiar historial de red (MEJORADA)
function Clean-NetworkHistory {
    param (
        [string]$FilePath,
        [int]$MaxDays = 7,
        [int]$MaxEntries = 2000  # Límite de entradas para evitar archivos muy grandes
    )
    
    if (-not (Test-Path $FilePath)) {
        return
    }
    
    try {
        $NetworkHistory = Get-NetworkHistory -FilePath $FilePath
        
        if ($NetworkHistory.Count -eq 0) {
            return
        }
        
        # Filtrar por fecha y cantidad
        $CutoffDate = (Get-Date).AddDays(-$MaxDays)
        $FilteredHistory = $NetworkHistory | Where-Object { 
            $_.Timestamp -ge $CutoffDate 
        } | Sort-Object Timestamp -Descending | Select-Object -First $MaxEntries
        
        # Solo reescribir si hay cambios significativos
        if ($FilteredHistory.Count -lt ($NetworkHistory.Count * 0.8)) {
            $NewContent = $FilteredHistory | Sort-Object Timestamp | ForEach-Object {
                "$($_.Timestamp.ToString('dd/MM/yyyy HH:mm:ss'))|$($_.Bytes)"
            }
            
            $NewContent | Set-Content -Path $FilePath -Encoding UTF8 -Force
            Write-Log "Historial de red limpiado: $($NetworkHistory.Count) → $($FilteredHistory.Count) entradas" "INFO"
        }
    }
    catch {
        Write-Log "Error limpiando historial de red: $($_.Exception.Message)" "ERROR"
    }
}

# Función para verificar procesos críticos
function Test-CriticalProcesses {
    $RunningCritical = @()
    foreach ($ProcessName in $CriticalProcesses) {
        $Process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        if ($Process) { $RunningCritical += $ProcessName }
    }
    return $RunningCritical
}

# Función para escribir en el log de ejecuciones
function Write-ExecutionLog {
    param (
        [double]$IdleMinutes,
        [double]$NetworkKB,
        [string]$ShutdownTime = "-"
    )
    $Timestamp = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    $FormattedIdleMinutes = [math]::Round($IdleMinutes, 2)
    $FormattedNetworkKB = [math]::Round($NetworkKB, 2)
    $LogEntry = "$Timestamp | Inactividad: $FormattedIdleMinutes minutos | Tráfico: $FormattedNetworkKB KB | Apagado: $ShutdownTime"
    
    if (Add-ContentSafe -Path $LastRunFile -Value $LogEntry) {
        # Write-Log "Entrada escrita en log de ejecuciones correctamente" # Eliminado del log
    }
}

# Función para verificar permisos de escritura
function Test-WritePermissions {
    param ([string]$Path)
    try {
        $TestFile = Join-Path $Path "test_permissions.tmp"
        "test" | Out-File -FilePath $TestFile -Encoding UTF8 -ErrorAction Stop
        Remove-Item $TestFile -ErrorAction SilentlyContinue
        return $true
    }
    catch { return $false }
}

# Función para mostrar advertencia de apagado
function Show-ShutdownWarning {
    param ([int]$Seconds = $ShutdownWarningSeconds)
    try {
        $message = "El equipo se apagará en $Seconds segundos debido a inactividad. Presione cualquier tecla o mueva el mouse para cancelar."
        Start-Process -FilePath "msg" -ArgumentList "*", "/time:$Seconds", $message -NoNewWindow -Wait:$false -ErrorAction Stop
        Write-Log "Advertencia de apagado mostrada ($Seconds segundos)"
        Start-Sleep -Seconds $Seconds
        
        $LastInput = New-Object AutoShutdown_LastInputInfo
        $LastInput.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($LastInput)
        $null = [AutoShutdown_IdleUser]::GetLastInputInfo([ref]$LastInput)
        $CurrentTickCount = [AutoShutdown_IdleUser]::GetTickCount()
        $NewIdleTime = [math]::Max(0, [int64]($CurrentTickCount - $LastInput.dwTime) / 1000)
        
        if ($NewIdleTime -lt 30) {
            Write-Log "Apagado cancelado por actividad del usuario"
            return $false
        }
        return $true
    }
    catch {
        if ($_.Exception.Message -match "msg|message") {
            Write-Log "Comando msg no disponible: $($_.Exception.Message)" "WARN"
        }
        else {
            Write-Log "Error en notificación: $($_.Exception.Message)" "WARN"
        }
        return $true
    }
}

# Función para validar la clave API
function Test-ApiKey {
    param ([string]$ApiKey)
    try {
        if (-not (Test-Path $ControlMerossPath)) {
            Write-Log "ERROR: control-meross.ps1 no encontrado: $ControlMerossPath" "ERROR"
            return $false
        }
        if (-not $ApiKey) {
            Write-Log "ERROR: Clave API no proporcionada" "ERROR"
            return $false
        }
        
        $StartTime = Get-Date
        
        $outputFile = "$env:TEMP\apikey_test_output_$((Get-Date).Ticks).txt"
        $errorFile = "$env:TEMP\apikey_test_error_$((Get-Date).Ticks).txt"
        
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-ExecutionPolicy", "Bypass", "-File", $ControlMerossPath,
            "cancel", "-JobId", "test", "-ApiKey", $ApiKey
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile -ErrorAction Stop
        
        $output = Get-Content $outputFile -Encoding UTF8 -ErrorAction SilentlyContinue
        $errorOutput = Get-Content $errorFile -Encoding UTF8 -ErrorAction SilentlyContinue
        $response = ($output + $errorOutput) -join ' '
        
        $ElapsedTime = ((Get-Date) - $StartTime).TotalSeconds
        if ($response -match "\(404\)\s*No\s*se\s*encontró") {
            Write-Log "[APIKEY] Clave API validada correctamente"
            return $true
        }
        elseif ($response -match "\(401\)\s*No\s*autorizado") {
            Write-Log "[APIKEY] ERROR: Clave API inválida" "ERROR"
            return $false
        }
        else {
            Write-Log "[APIKEY] ERROR: Respuesta inesperada de API" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "[APIKEY] Error verificando clave API: $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        Remove-Item $outputFile, $errorFile -ErrorAction SilentlyContinue
    }
}

# Función para mantener activo el servicio Meross
function Invoke-KeepAlive {
    try {
        if (-not (Test-Path $ControlMerossPath)) {
            Write-Log "ERROR: control-meross.ps1 no encontrado: $ControlMerossPath" "ERROR"
            return $false
        }
        
        $outputFile = "$env:TEMP\keepalive_output_$((Get-Date).Ticks).txt"
        $errorFile = "$env:TEMP\keepalive_error_$((Get-Date).Ticks).txt"
        
        $StartTime = Get-Date
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-ExecutionPolicy", "Bypass", "-File", $ControlMerossPath, "status"
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile -ErrorAction Stop
        
        $output = Get-Content $outputFile -Encoding UTF8 -ErrorAction SilentlyContinue
        $ElapsedTime = ((Get-Date) - $StartTime).TotalSeconds
        
        if ($process.ExitCode -eq 0 -and $output -match "✅|Servicio activo") {
            Write-Log "[KEEPALIVE] Servicio activo ($([math]::Round($ElapsedTime, 2)) seg)"
            return $ElapsedTime
        }
        else {
            Write-Log "ERROR: Fallo en verificación de servicio" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Error en keep-alive: $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        Remove-Item $outputFile, $errorFile -ErrorAction SilentlyContinue
    }
}

# Función para programar apagado de KodiPlex
function Schedule-KodiPlexShutdown {
    param (
        [int]$DelayMinutes = 1,
        [string]$ApiKey
    )
    try {
        if (-not (Test-Path $ControlMerossPath)) {
            Write-Log "ERROR: control-meross.ps1 no encontrado: $ControlMerossPath" "ERROR"
            return $false
        }
        if (-not $ApiKey) {
            Write-Log "ERROR: Clave API no proporcionada" "ERROR"
            return $false
        }
        
        Write-Log "Programando apagado de KodiPlex en $DelayMinutes minuto(s)"
        $retryCount = 0
        $success = $false
        
        while (-not $success -and $retryCount -lt $MerossMaxRetries) {
            try {
                $outputFile = "$env:TEMP\kodiplex_output_$((Get-Date).Ticks).txt"
                $errorFile = "$env:TEMP\kodiplex_error_$((Get-Date).Ticks).txt"
                
                $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
                    "-ExecutionPolicy", "Bypass", "-File", $ControlMerossPath,
                    "timer-off", "KodiPlex", $DelayMinutes, "-ApiKey", $ApiKey
                ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile -ErrorAction Stop
                
                $output = Get-Content $outputFile -Encoding UTF8 -ErrorAction SilentlyContinue
                
                if ($process.ExitCode -eq 0 -and $output -match "✅|programado|success|timer.*set") {
                    Write-Log "KodiPlex programado correctamente"
                    $success = $true
                    return $true
                }
                else {
                    Write-Log "ERROR: Fallo en programación (Exit: $($process.ExitCode))" "ERROR"
                }
            }
            catch {
                Write-Log "ERROR: Intento $($retryCount + 1) fallido: $($_.Exception.Message)" "ERROR"
            }
            finally {
                Remove-Item $outputFile, $errorFile -ErrorAction SilentlyContinue
            }
            
            $retryCount++
            if ($retryCount -lt $MerossMaxRetries) {
                $backoffDelay = [math]::Pow(2, $retryCount - 1) * 500
                Start-Sleep -Milliseconds $backoffDelay
            }
        }
        
        Write-Log "ERROR: No se pudo programar KodiPlex tras $MerossMaxRetries intentos" "ERROR"
        return $false
    }
    catch {
        Write-Log "Error inesperado programando KodiPlex: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Función para obtener estadísticas de red actuales (MEJORADA)
function Get-NetworkStatistics {
    try {
        # Obtener adaptadores activos excluyendo virtuales y loopback
        $NetworkAdapters = Get-NetAdapterStatistics -ErrorAction Stop | Where-Object { 
            $_.Name -notlike "*Loopback*" -and 
            $_.Name -notlike "*Teredo*" -and 
            $_.Name -notlike "*isatap*" -and
            $_.Name -notlike "*VMware*" -and
            $_.Name -notlike "*VirtualBox*" -and
            $_.Name -notlike "*Hyper-V*" -and
            ($_.ReceivedBytes -gt 0 -or $_.SentBytes -gt 0)
        }
        
        if ($NetworkAdapters) {
            # Calcular total de bytes y obtener detalles por adaptador
            $TotalReceived = ($NetworkAdapters | Measure-Object -Property ReceivedBytes -Sum).Sum
            $TotalSent = ($NetworkAdapters | Measure-Object -Property SentBytes -Sum).Sum
            $TotalBytes = [uint64]($TotalReceived + $TotalSent)
            
            # Log de debug para ver adaptadores activos
            if ($DebugMode) {
                Write-Log "Adaptadores de red activos:" "DEBUG"
                foreach ($adapter in $NetworkAdapters) {
                    $adapterTotalMB = [math]::Round(($adapter.ReceivedBytes + $adapter.SentBytes) / 1024 / 1024, 2)
                    Write-Log "  - $($adapter.Name): $adapterTotalMB MB total" "DEBUG"
                }
            }
            
            return @{
                TotalBytes = $TotalBytes
                TotalReceived = [uint64]$TotalReceived
                TotalSent = [uint64]$TotalSent
                AdapterCount = $NetworkAdapters.Count
                Success = $true
            }
        }
        else {
            Write-Log "No se encontraron adaptadores de red activos" "WARN"
            return @{
                TotalBytes = [uint64]0
                TotalReceived = [uint64]0
                TotalSent = [uint64]0
                AdapterCount = 0
                Success = $false
            }
        }
    }
    catch {
        Write-Log "Error obteniendo estadísticas de red: $($_.Exception.Message)" "ERROR"
        return @{
            TotalBytes = [uint64]0
            TotalReceived = [uint64]0
            TotalSent = [uint64]0
            AdapterCount = 0
            Success = $false
        }
    }
}

# Función para detectar reinicio real de contadores
function Test-CounterReset {
    param (
        [uint64]$CurrentBytes,
        [array]$RecentHistory,
        [double]$MaxResetThreshold = 0.1  # 10% del valor anterior
    )
    
    if ($RecentHistory.Count -eq 0) {
        return $false
    }
    
    # Obtener las últimas 3 entradas para análisis
    $LastEntries = $RecentHistory | Sort-Object Timestamp -Descending | Select-Object -First 3
    
    # Si el valor actual es menor que el último y la diferencia es significativa
    $LastBytes = $LastEntries[0].Bytes
    if ($CurrentBytes -lt $LastBytes) {
        $Reduction = ($LastBytes - $CurrentBytes) / $LastBytes
        
        # Si la reducción es mayor al threshold, considerar como reinicio
        if ($Reduction -gt $MaxResetThreshold) {
            if ($DebugMode) {
                Write-Log "Posible reinicio detectado: Reducción de $([math]::Round($Reduction * 100, 1))%" "DEBUG"
            }
            return $true
        }
    }
    
    return $false
}

# Función para calcular tráfico de red en el período especificado (MEJORADA)
function Get-NetworkTrafficInPeriod {
    param (
        [uint64]$CurrentBytes,
        [datetime]$CurrentTime,
        [array]$NetworkHistory,
        [int]$IntervalMinutes,
        [int]$TimeMarginSeconds = 30
    )
    
    # Calcular tiempo de corte con margen
    $CutoffTime = $CurrentTime.AddMinutes(-$IntervalMinutes).AddSeconds(-$TimeMarginSeconds)
    
    # Filtrar historial relevante
    $RelevantHistory = $NetworkHistory | Where-Object { 
        $_.Timestamp -ge $CutoffTime 
    } | Sort-Object Timestamp
    
    if ($DebugMode) {
        Write-Log "Período de análisis: $($CutoffTime.ToString('HH:mm:ss')) - $($CurrentTime.ToString('HH:mm:ss'))" "DEBUG"
        Write-Log "Entradas en el período: $($RelevantHistory.Count)" "DEBUG"
        Write-Log "Bytes actuales: $([math]::Round($CurrentBytes/1024/1024, 2)) MB" "DEBUG"
    }
    
    # Caso 1: Sin historial en el período
    if ($RelevantHistory.Count -eq 0) {
        if ($NetworkHistory.Count -gt 0) {
            # Usar la entrada más reciente disponible
            $LastEntry = $NetworkHistory | Sort-Object Timestamp -Descending | Select-Object -First 1
            $TimeDiff = ($CurrentTime - $LastEntry.Timestamp).TotalMinutes
            
            if ($TimeDiff -gt ($IntervalMinutes * 2)) {
                # Si es muy antigua, asumir tráfico cero
                Write-Log "Historial muy antiguo ($([math]::Round($TimeDiff, 1)) min). Asumiendo tráfico cero" "WARN"
                return [uint64]0
            }
            
            # Verificar si hubo reinicio real
            if (Test-CounterReset -CurrentBytes $CurrentBytes -RecentHistory @($LastEntry)) {
                Write-Log "Reinicio de contadores detectado. Usando valor actual: $([math]::Round($CurrentBytes/1024, 2)) KB" "INFO"
                return [uint64]$CurrentBytes
            }
            
            # Cálculo normal con entrada antigua
            if ($CurrentBytes -ge $LastEntry.Bytes) {
                $TrafficBytes = $CurrentBytes - $LastEntry.Bytes
                Write-Log "Calculando desde entrada antigua ($([math]::Round($TimeDiff, 1)) min): $([math]::Round($TrafficBytes/1024, 2)) KB" "INFO"
                return [uint64]$TrafficBytes
            } else {
                # Posible fluctuación, usar diferencia absoluta si es pequeña
                $Diff = $LastEntry.Bytes - $CurrentBytes
                if ($Diff -lt ($LastEntry.Bytes * 0.05)) {  # Menos del 5%
                    Write-Log "Fluctuación menor detectada. Asumiendo tráfico mínimo" "DEBUG"
                    return [uint64]($CurrentBytes * 0.01)  # 1% como estimación
                } else {
                    Write-Log "Posible reinicio significativo. Usando valor actual" "WARN"
                    return [uint64]$CurrentBytes
                }
            }
        } else {
            Write-Log "Sin historial disponible. Asumiendo tráfico cero" "INFO"
            return [uint64]0
        }
    }
    
    # Caso 2: Historial disponible en el período
    $OldestEntry = $RelevantHistory[0]
    $TimePeriod = ($CurrentTime - $OldestEntry.Timestamp).TotalMinutes
    
    if ($DebugMode) {
        Write-Log "Entrada más antigua: $($OldestEntry.Timestamp.ToString('HH:mm:ss')) - $([math]::Round($OldestEntry.Bytes/1024/1024, 2)) MB" "DEBUG"
        Write-Log "Período real de cálculo: $([math]::Round($TimePeriod, 2)) minutos" "DEBUG"
    }
    
    # Verificar reinicio de contadores
    if (Test-CounterReset -CurrentBytes $CurrentBytes -RecentHistory $RelevantHistory) {
        # Buscar el punto más reciente después del reinicio
        $ValidEntries = $RelevantHistory | Where-Object { $_.Bytes -le $CurrentBytes } | Sort-Object Timestamp -Descending
        
        if ($ValidEntries.Count -gt 0) {
            $BaseEntry = $ValidEntries[0]
            $TrafficBytes = $CurrentBytes - $BaseEntry.Bytes
            $ActualPeriod = ($CurrentTime - $BaseEntry.Timestamp).TotalMinutes
            
            Write-Log "Calculando desde reinicio: $([math]::Round($TrafficBytes/1024, 2)) KB en $([math]::Round($ActualPeriod, 2)) min" "INFO"
            return [uint64]$TrafficBytes
        } else {
            Write-Log "Reinicio completo detectado. Usando valor total actual" "WARN"
            return [uint64]$CurrentBytes
        }
    }
    
    # Cálculo normal
    if ($CurrentBytes -ge $OldestEntry.Bytes) {
        $TrafficBytes = $CurrentBytes - $OldestEntry.Bytes
        
        if ($DebugMode) {
            Write-Log "Tráfico calculado normalmente: $([math]::Round($TrafficBytes/1024, 2)) KB en $([math]::Round($TimePeriod, 2)) min" "DEBUG"
            Write-Log "Tasa promedio: $([math]::Round(($TrafficBytes/1024)/$TimePeriod, 2)) KB/min" "DEBUG"
        }
        
        return [uint64]$TrafficBytes
    } else {
        # El valor actual es menor que el histórico, pero no se detectó reinicio
        # Podría ser una fluctuación menor
        $Difference = $OldestEntry.Bytes - $CurrentBytes
        $PercentageDiff = $Difference / $OldestEntry.Bytes
        
        if ($PercentageDiff -lt 0.02) {  # Menos del 2% de diferencia
            Write-Log "Fluctuación menor detectada ($([math]::Round($PercentageDiff * 100, 2))%). Asumiendo tráfico mínimo" "DEBUG"
            return [uint64]($CurrentBytes * 0.005)  # 0.5% como estimación conservadora
        } else {
            Write-Log "Anomalía en contadores. Diferencia: $([math]::Round($Difference/1024, 2)) KB ($([math]::Round($PercentageDiff * 100, 2))%)" "WARN"
            return [uint64]$CurrentBytes
        }
    }
}

# Función para leer historial de red
function Get-NetworkHistory {
    param ([string]$FilePath)
    
    $NetworkHistory = @()
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Historial de red no existe. Creando archivo nuevo"
        return $NetworkHistory
    }
    
    try {
        $rawContent = Get-Content $FilePath -Encoding UTF8 -ErrorAction Stop
        $NetworkHistory = $rawContent | ForEach-Object {
            $parts = $_ -split "\|"
            if ($parts.Count -eq 2 -and $parts[0] -match '^\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2}$' -and $parts[1] -match '^\d+$') {
                try {
                    [PSCustomObject]@{
                        Timestamp = [datetime]::ParseExact($parts[0], "dd/MM/yyyy HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
                        Bytes = [uint64]$parts[1]
                    }
                }
                catch {
                    Write-Log "Error parseando línea de historial: $_" "WARN"
                    $null
                }
            }
            else {
                $null
            }
        } | Where-Object { $_ -ne $null } | Sort-Object Timestamp
    }
    catch {
        Write-Log "Error leyendo historial de red: $($_.Exception.Message)" "ERROR"
    }
    
    return $NetworkHistory
}

# Lógica principal
try {
    Write-Log "=== INICIANDO VERIFICACIÓN DE APAGADO AUTOMÁTICO ==="
    Write-Log "Versión del script: $ScriptVersion"
    Write-Log "Configuración: Inactividad $IdleThresholdMinutes min, Red $NetworkThresholdKB KB en $NetworkIntervalMinutes min"
    Write-Log "Modo de ejecución: $(if ($isInteractive = try { [bool]$Host.UI.RawUI } catch { $false }) {'Interactivo'} else {'No interactivo'})"

    # Validar directorio de logs
    if (-not (Test-Path $LogDirectory)) {
        Write-Log "ERROR: Directorio de logs no existe: $LogDirectory" "ERROR"
        throw "Directorio de logs no existe"
    }

    # Verificar permisos de escritura
    if (-not (Test-WritePermissions -Path $LogDirectory)) {
        Write-Log "ERROR: Sin permisos de escritura en directorio de logs: $LogDirectory" "ERROR"
        throw "Sin permisos de escritura en directorio de logs"
    }

    # Verificar limpieza diaria
    $LastCleanup = if (Test-Path $LastCleanupFile) {
        try { [datetime]::ParseExact((Get-Content $LastCleanupFile -ErrorAction SilentlyContinue), "dd/MM/yyyy HH:mm:ss", $null) }
        catch { (Get-Date).AddDays(-1) }
    } else { (Get-Date).AddDays(-1) }
    if (((Get-Date) - $LastCleanup).TotalHours -ge 24) {
        Write-Log "Realizando limpieza diaria de logs"
        Clean-MainLogFile -FilePath $LogFile
        Clean-ExecutionLogFile -FilePath $LastRunFile
        Clean-NetworkHistory -FilePath $NetworkHistoryFile
        (Get-Date -Format "dd/MM/yyyy HH:mm:ss") | Out-File -FilePath $LastCleanupFile -Encoding UTF8
        Write-Log "Limpieza diaria completada"
    }
    else {
        Write-Log "Limpieza diaria no requerida: última limpieza en $($LastCleanup.ToString('dd/MM/yyyy HH:mm:ss'))"
    }

    # Realizar keep-alive del servicio Meross
    $KeepAliveResult = Invoke-KeepAlive
    if ($KeepAliveResult -is [double]) {
        # Log ya escrito en Invoke-KeepAlive
    }
    else {
        Write-Log "ADVERTENCIA: Fallo en keep-alive del servicio Meross" "WARN"
    }

    # Validar clave API
    $attempts = 0
    while ($attempts -lt $MaxApiKeyAttempts) {
        if (-not $ApiKey) {
            if ($isInteractive) {
                Write-Log "[APIKEY] No se proporcionó clave API. Intento $($attempts + 1)/$MaxApiKeyAttempts"
                $ApiKey = Read-Host "Introduzca la clave API (o presione Ctrl+C para cancelar)"
            }
            else {
                Write-Log "[APIKEY] ERROR: Clave API requerida para modo no interactivo" "ERROR"
                throw "Clave API requerida para modo no interactivo"
            }
        }
        if (Test-ApiKey -ApiKey $ApiKey) {
            break
        }
        else {
            $attempts++
            $remaining = $MaxApiKeyAttempts - $attempts
            Write-Log "[APIKEY] ERROR: Clave API inválida. Intento $($attempts)/$MaxApiKeyAttempts" "ERROR"
            if ($remaining -gt 0 -and $isInteractive) {
                Write-Host "Clave API inválida. Intentos restantes: $remaining" -ForegroundColor Red
                Write-Log "[APIKEY] Clave API inválida. Intentos restantes: $remaining"
                $ApiKey = $null
            }
            else {
                Write-Log "[APIKEY] ERROR: Máximo de intentos alcanzado" "ERROR"
                throw "Máximo de intentos alcanzado para clave API"
            }
        }
    }

    # Verificar tiempo de inactividad del usuario
    $LastInput = New-Object AutoShutdown_LastInputInfo
    $LastInput.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($LastInput)
    
    if (-not [AutoShutdown_IdleUser]::GetLastInputInfo([ref]$LastInput)) {
        Write-Log "ERROR: No se pudo obtener información de entrada del usuario" "ERROR"
        throw "No se pudo obtener información de entrada del usuario"
    }
    
    $CurrentTickCount = [AutoShutdown_IdleUser]::GetTickCount()
    $IdleTimeSeconds = [math]::Max(0, [int64]($CurrentTickCount - $LastInput.dwTime) / 1000)
    $IdleTimeMinutes = [math]::Round($IdleTimeSeconds / 60, 2)
    
    Write-Log "Tiempo de inactividad: $IdleTimeMinutes minutos ($IdleTimeSeconds segundos)"
    
    $ConditionsMet = $true
    $Reasons = @()
    
    if ($IdleTimeMinutes -lt $IdleThresholdMinutes) {
        $ConditionsMet = $false
        $Reasons += "Inactividad=No se cumple"
    }

    # Verificar actividad de red
    $CurrentTime = Get-Date
    $NetworkStats = Get-NetworkStatistics

    if (-not $NetworkStats.Success) {
        Write-Log "ADVERTENCIA: No se pudieron obtener estadísticas de red. Asumiendo tráfico cero" "WARN"
        $NetworkTrafficKB = 0
    }
    else {
        # Log de información de red si está en modo debug
        if ($DebugMode) {
            Write-Log "Estadísticas de red: $($NetworkStats.AdapterCount) adaptadores, $([math]::Round($NetworkStats.TotalBytes/1024/1024, 2)) MB total" "DEBUG"
        }
        
        # Cargar historial de red
        $NetworkHistory = Get-NetworkHistory -FilePath $NetworkHistoryFile
        
        # Calcular tráfico en el período especificado
        $NetworkTrafficBytes = Get-NetworkTrafficInPeriod -CurrentBytes $NetworkStats.TotalBytes -CurrentTime $CurrentTime -NetworkHistory $NetworkHistory -IntervalMinutes $NetworkIntervalMinutes
        $NetworkTrafficKB = [math]::Round($NetworkTrafficBytes / 1024, 2)
        
        # Log adicional para debugging
        if ($DebugMode -and $NetworkTrafficKB -gt 0) {
            $TrafficRate = $NetworkTrafficKB / $NetworkIntervalMinutes
            Write-Log "Tasa de tráfico: $([math]::Round($TrafficRate, 2)) KB/min" "DEBUG"
        }
    }

    # Actualizar historial de red
    try {
        $HistoryEntry = "$($CurrentTime.ToString('dd/MM/yyyy HH:mm:ss'))|$($NetworkStats.TotalBytes)"
        if (Add-ContentSafe -Path $NetworkHistoryFile -Value $HistoryEntry) {
            # Limpiar historial solo ocasionalmente para evitar overhead
            $CleanupChance = Get-Random -Minimum 1 -Maximum 100
            if ($CleanupChance -le 5) {  # 5% de probabilidad de limpieza
                Clean-NetworkHistory -FilePath $NetworkHistoryFile
            }
        }
        else {
            Write-Log "ADVERTENCIA: No se pudo actualizar historial de red" "WARN"
        }
    }
    catch {
        Write-Log "ADVERTENCIA: Error actualizando historial de red: $($_.Exception.Message)" "WARN"
    }

    # Evaluación de la condición de red con información más detallada
    if ($NetworkTrafficKB -gt $NetworkThresholdKB) {
        $ExcessTraffic = $NetworkTrafficKB - $NetworkThresholdKB
        Write-Log "Actividad de red detectada: $NetworkTrafficKB KB en $NetworkIntervalMinutes min (exceso: $([math]::Round($ExcessTraffic, 2)) KB)"
        $ConditionsMet = $false
        $Reasons += "Red=No se cumple"
    }
    else {
        Write-Log "Baja actividad de red: $NetworkTrafficKB KB en $NetworkIntervalMinutes min (límite: $NetworkThresholdKB KB)"
    }

    # Verificar procesos críticos
    $CriticalProcessesRunning = Test-CriticalProcesses
    if ($CriticalProcessesRunning.Count -gt 0) {
        Write-Log "Procesos críticos en ejecución: $($CriticalProcessesRunning -join ', ')"
        $ConditionsMet = $false
        $Reasons += "Procesos críticos=Sí"
    }
    else {
        Write-Log "No se encontraron procesos críticos"
    }

    # Evaluar condiciones para apagado
    if (-not $ConditionsMet) {
        Write-Log "Condiciones no cumplidas. Razones: $($Reasons -join ', ')"
        Write-ExecutionLog -IdleMinutes $IdleTimeMinutes -NetworkKB $NetworkTrafficKB
    }
    else {
        # Mostrar advertencia de apagado si está en modo interactivo
        if ($isInteractive -and $ShutdownWarningSeconds -gt 0) {
            if (-not (Show-ShutdownWarning -Seconds $ShutdownWarningSeconds)) {
                Write-Log "Apagado cancelado por actividad del usuario"
                Write-ExecutionLog -IdleMinutes $IdleTimeMinutes -NetworkKB $NetworkTrafficKB
                $ConditionsMet = $false
                $Reasons += "Advertencia cancelada=Sí"
            }
        }
    }

    # Preparar log final antes de apagado
    if ($ConditionsMet) {
        Write-Log "Iniciando secuencia de apagado"
        
        # Programar apagado de KodiPlex
        $KodiPlexSuccess = Schedule-KodiPlexShutdown -DelayMinutes $KodiPlexShutdownDelayMinutes -ApiKey $ApiKey
        
        if (-not $KodiPlexSuccess) {
            Write-Log "ADVERTENCIA: No se pudo programar el apagado de KodiPlex. Continuando con apagado del PC" "WARN"
        }
        
        # Cancelar apagados previos
        try {
            $outputFile = "$env:TEMP\shutdown_cancel_output_$((Get-Date).Ticks).txt"
            $errorFile = "$env:TEMP\shutdown_cancel_error_$((Get-Date).Ticks).txt"
            $CancelProcess = Start-Process -FilePath "shutdown.exe" -ArgumentList "/a" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile
            $errorOutput = Get-Content $errorFile -Encoding UTF8 -ErrorAction SilentlyContinue
            Remove-Item $outputFile, $errorFile -ErrorAction SilentlyContinue
            if ($CancelProcess.ExitCode -ne 0 -and $errorOutput -notmatch "1116") {
                Write-Log "ADVERTENCIA: Error al cancelar apagados previos: $errorOutput (Exit Code: $($CancelProcess.ExitCode))" "WARN"
            }
        }
        catch {
            Write-Log "ADVERTENCIA: Excepción al cancelar apagados previos: $($_.Exception.Message)" "WARN"
        }
    }

    # Registro final
    Write-Log "Resumen:"
    Write-Log "  • Inactividad: $IdleTimeMinutes minutos (≥$IdleThresholdMinutes min: $(if ($IdleTimeMinutes -ge $IdleThresholdMinutes) {'Se cumple'} else {'No se cumple'}))"
    Write-Log "  • Red: $NetworkTrafficKB KB (≤$NetworkThresholdKB KB: $(if ($NetworkTrafficKB -le $NetworkThresholdKB) {'Se cumple'} else {'No se cumple'}))"
    Write-Log "  • Procesos críticos: $($CriticalProcessesRunning.Count) $(if ($CriticalProcessesRunning.Count -eq 0) {'(Ninguno: Se cumple)'} else {'(Sí: No se cumple)'})"
    Write-Log "  • KodiPlex: $(if ($null -eq $KodiPlexSuccess) {'No programado'} elseif ($KodiPlexSuccess) {'Programado correctamente'} else {'Error en programación'})"
    Write-Log "  • Sistema: $(if ($ConditionsMet) {'Apagado iniciado'} else {'No apagado'})"

    if ($ConditionsMet) {
        Write-Log "Iniciando apagado inmediato del PC"
    }

    Write-Log "=== VERIFICACIÓN COMPLETADA ==="

    # Escribir log al archivo antes de apagar
    Flush-LogBuffer

    # Proceder con apagado si todas las condiciones se cumplen
    if ($ConditionsMet) {
        # Iniciar apagado inmediato del PC
        try {
            $ShutdownArgs = @("/s", "/f", "/t", $PCShutdownDelaySeconds, "/c", "AutoShutdown")
            $outputFile = "$env:TEMP\shutdown_output_$((Get-Date).Ticks).txt"
            $errorFile = "$env:TEMP\shutdown_error_$((Get-Date).Ticks).txt"
            
            $ShutdownProcess = Start-Process -FilePath "shutdown.exe" -ArgumentList $ShutdownArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile -ErrorAction Stop
            
            $errorOutput = Get-Content $errorFile -Encoding UTF8 -ErrorAction SilentlyContinue
            Remove-Item $outputFile, $errorFile -ErrorAction SilentlyContinue
            
            if ($ShutdownProcess.ExitCode -ne 0) {
                throw "Fallo al iniciar apagado del sistema (Exit Code: $($ShutdownProcess.ExitCode)). Error: $errorOutput"
            }
        }
        catch {
            Write-Log "ERROR: Excepción al iniciar apagado del sistema: $($_.Exception.Message)" "ERROR"
            Flush-LogBuffer
            # Fallback con Stop-Computer
            try {
                Stop-Computer -Force -ErrorAction Stop
            }
            catch {
                Write-Log "ERROR: Fallo al iniciar apagado alternativo: $($_.Exception.Message)" "ERROR"
                Flush-LogBuffer
                exit 1
            }
        }
    }
}
catch {
    Write-Log "ERROR: Excepción en la ejecución principal: $($_.Exception.Message)" "ERROR"
    Flush-LogBuffer
    exit 1
}
finally {
    # Limpieza de archivos temporales
    try {
        $TempFiles = Get-ChildItem -Path $env:TEMP -Filter "*apagado*" -ErrorAction SilentlyContinue | 
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) }
        
        if ($TempFiles) {
            $TempFiles | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Log "Limpieza: $($TempFiles.Count) archivos temporales eliminados"
            Flush-LogBuffer
        }
    }
    catch {
        Write-Log "Advertencia en limpieza de archivos temporales: $($_.Exception.Message)" "WARN"
        Flush-LogBuffer
    }
}

exit 0