# Configurar codificación UTF-8 para caracteres especiales
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Configuración
$IdleThresholdMinutes = 60  # 60 minutos de inactividad
$IdleThresholdSeconds = $IdleThresholdMinutes * 60
$NetworkIntervalMinutes = 60  # Intervalo para medir tráfico de red
$NetworkThresholdKB = 10000  # Umbral de red en KB
$NetworkThresholdBytes = $NetworkThresholdKB * 1024
$ShutdownWarningSeconds = 30  # Tiempo de aviso antes del apagado
$MaxLogSizeMB = 1  # Límite de tamaño de logs en MB

# Procesos críticos que impiden el apagado
$CriticalProcesses = @("Teams", "Zoom", "obs64", "StreamlabsOBS", "chrome", "firefox")

# Rutas de archivos (con prefijo reg_ para agrupación)
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptPath "reg_apagado.log"
$LastRunFile = Join-Path $ScriptPath "reg_ejecutado.log"
$NetworkHistoryFile = Join-Path $ScriptPath "reg_trafico_historial.log"
$LastCleanupFile = Join-Path $ScriptPath "reg_fecha_limpieza.log"

# Función para escribir logs con timestamp y manejo de concurrencia
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    $LogEntry = "[$Level] $Timestamp - $Message"
    
    $maxRetries = 3
    $retryCount = 0
    $success = $false
    
    while (-not $success -and $retryCount -lt $maxRetries) {
        try {
            Add-Content -Path $LogFile -Value $LogEntry -Encoding UTF8 -ErrorAction Stop
            $success = $true
        }
        catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                Write-Host "Error escribiendo en ${LogFile} tras $maxRetries intentos: $($_.Exception.Message)"
            } else {
                $randomDelay = Get-Random -Minimum 0 -Maximum 50
                Start-Sleep -Milliseconds (100 * $retryCount + $randomDelay)
            }
        }
    }
    Write-Host $LogEntry
}

# Add-ContentSafe: Escribe contenido en un archivo con reintentos para manejar concurrencia
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
                Write-Log "Error escribiendo en ${Path} tras $maxRetries intentos: $($_.Exception.Message)" "ERROR"
                return $false
            } else {
                $randomDelay = Get-Random -Minimum 0 -Maximum 50
                Start-Sleep -Milliseconds (100 * $retryCount + $randomDelay)
            }
        }
    }
    return $false
}

# Out-FileSafe: Escribe archivos completos con manejo de concurrencia usando archivo temporal
function Out-FileSafe {
    param (
        [string[]]$Content,
        [string]$FilePath
    )
    
    $maxRetries = 3
    $retryCount = 0
    
    # Limpieza de archivos temporales residuales
    Get-ChildItem -Path (Split-Path -Parent $FilePath) -Filter "*.tmp_*" | Remove-Item -Force -ErrorAction SilentlyContinue
    
    while ($retryCount -lt $maxRetries) {
        $tempFile = "${FilePath}.tmp_$(Get-Random)"
        try {
            $Content | Out-File -FilePath $tempFile -Encoding UTF8 -Force -ErrorAction Stop
            Move-Item -Path $tempFile -Destination $FilePath -Force -ErrorAction Stop
            return $true
        }
        catch {
            if (Test-Path $tempFile) {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                if ($_.Exception.Message -match "Move-Item|mover|move") {
                    Write-Log "Error moviendo archivo temporal a ${FilePath}: $($_.Exception.Message)" "ERROR"
                } else {
                    Write-Log "Error escribiendo archivo temporal para ${FilePath}: $($_.Exception.Message)" "ERROR"
                }
                return $false
            } else {
                $randomDelay = Get-Random -Minimum 0 -Maximum 100
                Start-Sleep -Milliseconds (200 * $retryCount + $randomDelay)
            }
        }
    }
    return $false
}

# Test-LogFileSize: Verifica si el archivo excede el tamaño máximo
function Test-LogFileSize {
    param (
        [string]$FilePath,
        [double]$MaxSizeMB = $MaxLogSizeMB
    )
    
    if (-not (Test-Path $FilePath)) {
        return $false
    }
    
    try {
        $fileSizeMB = (Get-Item $FilePath -ErrorAction Stop).Length / 1MB
        return $fileSizeMB -gt $MaxSizeMB
    }
    catch {
        Write-Log "Error verificando tamaño de ${FilePath}: $($_.Exception.Message)" "WARN"
        return $false
    }
}

# Clean-MainLogFile: Limpia el archivo de log principal manteniendo las últimas 48 horas
function Clean-MainLogFile {
    param (
        [string]$FilePath
    )
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Archivo de log principal no existe: ${FilePath}"
        return
    }
    
    if (Test-LogFileSize -FilePath $FilePath) {
        Write-Log "Archivo ${FilePath} excede ${MaxLogSizeMB} MB. Forzando limpieza completa." "WARN"
        try {
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Archivo ${FilePath} limpiado por límite de tamaño."
            return
        }
        catch {
            Write-Log "Error limpiando archivo por tamaño ${FilePath}: $($_.Exception.Message)" "ERROR"
            return
        }
    }
    
    try {
        $CutoffTime = (Get-Date).AddHours(-48)
        $KeptLines = @()
        $currentSession = @()
        $entryCount = 0
        
        $streamReader = [System.IO.StreamReader]::new($FilePath, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $streamReader.ReadLine())) {
                if ($line -match '^\[.*?\]\s(\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2})\s-') {
                    try {
                        $lineTimestamp = [datetime]::ParseExact($Matches[1], "dd/MM/yyyy HH:mm:ss", $null)
                        if ($lineTimestamp -ge $CutoffTime) {
                            if ($currentSession.Count -gt 0) {
                                $hasValidTimestamp = $false
                                foreach ($sessionLine in $currentSession) {
                                    if ($sessionLine -match '^\[.*?\]\s\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2}\s-') {
                                        $hasValidTimestamp = $true
                                        break
                                    }
                                }
                                if ($hasValidTimestamp) {
                                    $KeptLines += $currentSession
                                }
                                $currentSession = @()
                            }
                            $currentSession += $line
                            $entryCount++
                        }
                        else {
                            $currentSession = @()
                        }
                    }
                    catch {
                        if ($currentSession.Count -gt 0) {
                            $currentSession += $line
                        }
                    }
                }
                else {
                    if ($currentSession.Count -gt 0) {
                        $currentSession += $line
                    }
                }
            }
        }
        finally {
            $streamReader.Close()
            $streamReader.Dispose()
        }
        
        if ($currentSession.Count -gt 0) {
            $hasValidTimestamp = $false
            foreach ($sessionLine in $currentSession) {
                if ($sessionLine -match '^\[.*?\]\s\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2}\s-') {
                    $hasValidTimestamp = $true
                    break
                }
            }
            if ($hasValidTimestamp) {
                $KeptLines += $currentSession
            }
        }
        
        if ($KeptLines.Count -gt 0) {
            if (Out-FileSafe -Content $KeptLines -FilePath $FilePath) {
                Write-Log "Archivo de log principal limpiado. Entradas mantenidas: $entryCount"
            }
        } else {
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Archivo de log principal limpiado completamente (sin entradas recientes)"
        }
    }
    catch {
        Write-Log "Error limpiando log principal ${FilePath}: $($_.Exception.Message)" "ERROR"
    }
}

# Clean-ExecutionLogFile: Limpia el archivo de ejecuciones manteniendo las últimas 48 horas
function Clean-ExecutionLogFile {
    param (
        [string]$FilePath
    )
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Archivo de ejecuciones no existe: ${FilePath}"
        return
    }
    
    if (Test-LogFileSize -FilePath $FilePath) {
        Write-Log "Archivo ${FilePath} excede ${MaxLogSizeMB} MB. Forzando limpieza completa." "WARN"
        try {
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Archivo ${FilePath} limpiado por límite de tamaño."
            return
        }
        catch {
            Write-Log "Error limpiando archivo por tamaño ${FilePath}: $($_.Exception.Message)" "ERROR"
            return
        }
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
                Write-Log "Archivo de ejecuciones limpiado. Entradas mantenidas: $entryCount"
            }
        } else {
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Archivo de ejecuciones limpiado completamente (sin entradas recientes)"
        }
    }
    catch {
        Write-Log "Error limpiando archivo de ejecuciones ${FilePath}: $($_.Exception.Message)" "ERROR"
    }
}

# Clean-NetworkHistory: Limpia el historial de red manteniendo las últimas 48 horas
function Clean-NetworkHistory {
    param (
        [string]$FilePath
    )
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Historial de red no existe: ${FilePath}"
        return
    }
    
    if (Test-LogFileSize -FilePath $FilePath) {
        Write-Log "Archivo ${FilePath} excede ${MaxLogSizeMB} MB. Forzando limpieza completa." "WARN"
        try {
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Archivo ${FilePath} limpiado por límite de tamaño."
            return
        }
        catch {
            Write-Log "Error limpiando archivo por tamaño ${FilePath}: $($_.Exception.Message)" "ERROR"
            return
        }
    }
    
    try {
        $CutoffTime = (Get-Date).AddHours(-48)
        $KeptLines = @()
        $entryCount = 0
        
        $streamReader = [System.IO.StreamReader]::new($FilePath, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $streamReader.ReadLine())) {
                $parts = $line -split "\|"
                if ($parts.Count -eq 2 -and $parts[0] -match '^\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2}$' -and $parts[1] -match '^\d+$') {
                    try {
                        $lineTimestamp = [datetime]::ParseExact($parts[0], "dd/MM/yyyy HH:mm:ss", $null)
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
                Write-Log "Historial de red limpiado. Entradas mantenidas: $entryCount"
            }
        } else {
            Clear-Content -Path $FilePath -ErrorAction Stop
            Write-Log "Historial de red limpiado completamente (sin entradas recientes)"
        }
    }
    catch {
        Write-Log "Error limpiando historial de red ${FilePath}: $($_.Exception.Message)" "ERROR"
    }
}

# Test-CriticalProcesses: Verifica si hay procesos críticos ejecutándose
function Test-CriticalProcesses {
    $RunningCritical = @()
    foreach ($ProcessName in $CriticalProcesses) {
        $Process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        if ($Process) {
            $RunningCritical += $ProcessName
        }
    }
    return $RunningCritical
}

# Write-ExecutionLog: Escribe entrada en log de ejecuciones con formato consistente
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
        Write-Log "Entrada escrita en log de ejecuciones correctamente"
    }
}

# Test-WritePermissions: Valida permisos de escritura en el directorio
function Test-WritePermissions {
    param (
        [string]$Path
    )
    
    try {
        $TestFile = Join-Path $Path "test_permissions.tmp"
        "test" | Out-File -FilePath $TestFile -ErrorAction Stop
        Remove-Item $TestFile -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

# Show-ShutdownWarning: Muestra notificación antes del apagado y verifica actividad
function Show-ShutdownWarning {
    param (
        [int]$Seconds = $ShutdownWarningSeconds
    )
    
    try {
        $message = "El equipo se apagará en $Seconds segundos debido a inactividad. Presione cualquier tecla o mueva el mouse para cancelar."
        Start-Process -FilePath "msg" -ArgumentList "*", "/time:$Seconds", $message -NoNewWindow -Wait:$false -ErrorAction Stop
        Write-Log "Notificación de apagado mostrada al usuario ($Seconds segundos)"
        
        Start-Sleep -Seconds $Seconds
        
        $LastInput = New-Object AutoShutdown_LastInputInfo
        $LastInput.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($LastInput)
        $null = [AutoShutdown_IdleUser]::GetLastInputInfo([ref]$LastInput)
        $CurrentTickCount = [AutoShutdown_IdleUser]::GetTickCount()
        $NewIdleTime = [math]::Max(0, [int64]($CurrentTickCount - $LastInput.dwTime) / 1000)
        
        if ($NewIdleTime -lt 30) {
            Write-Log "Usuario detectado durante aviso de apagado. Cancelando apagado automático."
            return $false
        }
        
        return $true
    }
    catch {
        if ($_.Exception.Message -match "msg|message") {
            Write-Log "Comando msg no disponible o falló: $($_.Exception.Message)" "WARN"
        } else {
            Write-Log "Error inesperado en notificación: $($_.Exception.Message)" "WARN"
        }
        return $true
    }
}

# Schedule-KodiPlexShutdown: Programa apagado de KodiPlex antes del apagado del PC
function Schedule-KodiPlexShutdown {
    param (
        [int]$DelayMinutes = 1,
        [string]$ApiKey = "Apollo1991!"
    )
    
    try {
        Write-Log "🔌 Programando apagado de KodiPlex en $DelayMinutes minuto(s)..."
        
        # Buscar el script control-meross.ps1 en el mismo directorio
        $ControlMerossPath = Join-Path $ScriptPath "control-meross.ps1"
        
        if (-not (Test-Path $ControlMerossPath)) {
            Write-Log "❌ Script control-meross.ps1 no encontrado en: $ControlMerossPath" "ERROR"
            return $false
        }
        
        # Ejecutar comando con timeout de 30 segundos
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-ExecutionPolicy", "Bypass",
            "-File", $ControlMerossPath,
            "timer-off", "KodiPlex", $DelayMinutes,
            "-ApiKey", $ApiKey
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\kodiplex_output.txt" -RedirectStandardError "$env:TEMP\kodiplex_error.txt"
        
        # Verificar resultado
        if ($process.ExitCode -eq 0) {
            $output = Get-Content "$env:TEMP\kodiplex_output.txt" -ErrorAction SilentlyContinue
            if ($output -match "✅.*programado|success") {
                Write-Log "✅ KodiPlex programado para apagarse en $DelayMinutes minuto(s)"
                return $true
            } else {
                Write-Log "⚠️ KodiPlex: Respuesta inesperada - $($output -join ' ')" "WARN"
                return $false
            }
        } else {
            $errorOutput = Get-Content "$env:TEMP\kodiplex_error.txt" -ErrorAction SilentlyContinue
            Write-Log "❌ Error programando KodiPlex (Exit: $($process.ExitCode)): $($errorOutput -join ' ')" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "💥 Excepción programando KodiPlex: $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        # Limpiar archivos temporales
        Remove-Item "$env:TEMP\kodiplex_output.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\kodiplex_error.txt" -ErrorAction SilentlyContinue
    }
}

# Registrar inicio de ejecución
Write-Log "=== INICIANDO VERIFICACIÓN DE APAGADO AUTOMÁTICO ==="
Write-Log "Configuración: Inactividad $IdleThresholdMinutes min, Red $NetworkThresholdKB KB en $NetworkIntervalMinutes min"

# Validar permisos de escritura
if (-not (Test-WritePermissions -Path $ScriptPath)) {
    Write-Log "ERROR: Sin permisos de escritura en el directorio del script: $ScriptPath" "ERROR"
    Write-Log "=== VERIFICACIÓN COMPLETADA (ERROR PERMISOS) ==="
    Add-ContentSafe -Path $LogFile -Value ""
    exit 1
}

# Gestión de limpieza diaria con validación de formato
$LastCleanupFile = Join-Path $ScriptPath "reg_fecha_limpieza.log"
$ShouldCleanup = $false

if (Test-Path $LastCleanupFile) {
    try {
        $LastCleanupStr = Get-Content $LastCleanupFile -ErrorAction Stop | Select-Object -First 1
        if ($LastCleanupStr -match '^\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2}$') {
            $LastCleanupTime = [datetime]::ParseExact($LastCleanupStr, "dd/MM/yyyy HH:mm:ss", $null)
            if ((Get-Date) -gt $LastCleanupTime.AddHours(24)) {
                $ShouldCleanup = $true
            }
        } else {
            Write-Log "Formato inválido en ${LastCleanupFile}. Forzando limpieza." "WARN"
            $ShouldCleanup = $true
        }
    }
    catch {
        Write-Log "Error leyendo archivo de fecha de limpieza. Forzando limpieza." "WARN"
        $ShouldCleanup = $true
    }
} else {
    $ShouldCleanup = $true
}

try {
    # Definir funciones nativas de Windows
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
        Write-Log "Error al agregar el tipo AutoShutdown_IdleUser: $($_.Exception.Message)" "ERROR"
        Write-ExecutionLog -IdleMinutes 0 -NetworkKB 0
        Write-Log "=== VERIFICACIÓN COMPLETADA (ERROR) ==="
        Add-ContentSafe -Path $LogFile -Value ""
        exit 1
    }

    # Obtener tiempo de inactividad
    $LastInput = New-Object AutoShutdown_LastInputInfo
    $LastInput.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($LastInput)
    $null = [AutoShutdown_IdleUser]::GetLastInputInfo([ref]$LastInput)
    $CurrentTickCount = [AutoShutdown_IdleUser]::GetTickCount()
    $IdleTime = [math]::Max(0, [int64]($CurrentTickCount - $LastInput.dwTime) / 1000)
    $IdleMinutes = [math]::Round($IdleTime/60, 2)
    
    Write-Log "Tiempo de inactividad actual: $IdleMinutes minutos ($([math]::Round($IdleTime, 0)) segundos)"

    # Verificar procesos críticos
    $CriticalRunning = Test-CriticalProcesses
    if ($CriticalRunning.Count -gt 0) {
        Write-Log "Procesos críticos detectados: $($CriticalRunning -join ', '). Cancelando apagado."
        Write-ExecutionLog -IdleMinutes $IdleMinutes -NetworkKB 0
        Write-Log "=== VERIFICACIÓN COMPLETADA (PROCESOS CRÍTICOS) ==="
        Add-ContentSafe -Path $LogFile -Value ""
        return
    }

    # Obtener tráfico de red actual
    $CurrentNetworkBytes = [uint64]0
    $NetworkAdaptersInfo = ""
    
    try {
        $NetworkActivity = Get-NetAdapterStatistics -ErrorAction Stop | Where-Object { $_.Name -notlike "*Loopback*" -and $_.Name -notlike "*Teredo*" }
        if ($NetworkActivity) {
            $CurrentNetworkBytes = [uint64](($NetworkActivity | Measure-Object -Property ReceivedBytes -Sum).Sum + 
                                           ($NetworkActivity | Measure-Object -Property SentBytes -Sum).Sum)
            $NetworkAdaptersInfo = $NetworkActivity.Name -join ', '
        } else {
            Write-Log "No se encontraron adaptadores de red activos válidos" "WARN"
            $NetworkAdaptersInfo = "Sin adaptadores activos"
        }
    }
    catch {
        Write-Log "Error obteniendo estadísticas de red: $($_.Exception.Message)" "ERROR"
        $CurrentNetworkBytes = [uint64]0
        $NetworkAdaptersInfo = "Error al obtener adaptadores"
    }

    $CurrentTimestamp = Get-Date
    Write-Log "Tráfico de red total actual: $([math]::Round($CurrentNetworkBytes/1MB, 2)) MB"
    Write-Log "Adaptadores de red: $NetworkAdaptersInfo"

    # Leer historial de tráfico
    $NetworkHistory = @()
    if (Test-Path $NetworkHistoryFile) {
        try {
            $NetworkHistory = Get-Content $NetworkHistoryFile -ErrorAction Stop | ForEach-Object {
                $parts = $_ -split "\|"
                if ($parts.Count -eq 2 -and $parts[0] -match '^\d{2}/\d{2}/\d{4}\s\d{2}:\d{2}:\d{2}$' -and $parts[1] -match '^\d+$') {
                    try {
                        [PSCustomObject]@{
                            Timestamp = [datetime]::ParseExact($parts[0], "dd/MM/yyyy HH:mm:ss", $null)
                            Bytes = [uint64]$parts[1]
                        }
                    }
                    catch {
                        Write-Log "Error parseando línea de historial de red: $_" "WARN"
                        $null
                    }
                }
            } | Where-Object { $_ -ne $null } | Sort-Object Timestamp
        }
        catch {
            Write-Log "Error leyendo historial de red: $($_.Exception.Message)" "ERROR"
        }
    }

    # Calcular tráfico en el intervalo
    $IntervalAgo = $CurrentTimestamp.AddMinutes(-$NetworkIntervalMinutes)
    $RecentHistory = $NetworkHistory | Where-Object { $_.Timestamp -ge $IntervalAgo }
    $RecentNetworkBytes = [uint64]0
    if ($RecentHistory.Count -gt 0) {
        $OldestBytes = [uint64]($RecentHistory | Select-Object -First 1).Bytes
        if ($CurrentNetworkBytes -ge $OldestBytes) {
            $RecentNetworkBytes = $CurrentNetworkBytes - $OldestBytes
        }
        else {
            Write-Log "Detectado reinicio de contadores de red. Tráfico establecido en valor actual." "WARN"
            $RecentNetworkBytes = $CurrentNetworkBytes
        }
    }
    else {
        Write-Log "Sin historial de red suficiente. Usando umbral como baseline para evitar apagado prematuro." "INFO"
        $RecentNetworkBytes = $NetworkThresholdBytes
    }
    $NetworkKB = [math]::Round($RecentNetworkBytes/1KB, 2)

    Write-Log "Tráfico en últimos $NetworkIntervalMinutes minutos: $NetworkKB KB"
    Write-Log "Umbral de tráfico: $NetworkThresholdKB KB"

    # Agregar registro actual al historial de red
    $networkLogEntry = "$($CurrentTimestamp.ToString('dd/MM/yyyy HH:mm:ss'))|$CurrentNetworkBytes"
    if (Add-ContentSafe -Path $NetworkHistoryFile -Value $networkLogEntry) {
        Write-Log "Entrada escrita en historial de red correctamente"
    }

    # Verificar condiciones
    $IdleCondition = $IdleTime -ge $IdleThresholdSeconds
    $NetworkCondition = $RecentNetworkBytes -lt $NetworkThresholdBytes

    Write-Log "Condición inactividad: $IdleCondition (≥$IdleThresholdMinutes min = $IdleThresholdSeconds seg)"
    Write-Log "Condición red: $NetworkCondition (<$NetworkThresholdKB KB)"

    if ($IdleCondition -and $NetworkCondition) {
        $ShutdownTime = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
        Write-Log "Condiciones cumplidas. Preparando apagado a las: $ShutdownTime"
        Write-ExecutionLog -IdleMinutes $IdleMinutes -NetworkKB $NetworkKB -ShutdownTime $ShutdownTime
        Write-Log "=== VERIFICACIÓN COMPLETADA (APAGANDO) ==="
        Add-ContentSafe -Path $LogFile -Value ""
        
    # Usar notificación interactiva
    if (Show-ShutdownWarning -Seconds $ShutdownWarningSeconds) {
    # Programar apagado de KodiPlex ANTES del apagado del PC
    $kodiPlexScheduled = Schedule-KodiPlexShutdown -DelayMinutes 1 -ApiKey "Apollo1991!"
    
    if ($kodiPlexScheduled) {
        Write-Log "✅ KodiPlex programado correctamente. Procediendo con apagado del PC."
        # Esperar 2 segundos para asegurar que la programación se completó
        Start-Sleep -Seconds 2
    } else {
        Write-Log "⚠️ No se pudo programar KodiPlex, pero continuando con apagado del PC" "WARN"
    }
    
    Stop-Computer -Force -ErrorAction Stop
} else {
    Write-Log "Apagado cancelado por interacción del usuario"
    Add-ContentSafe -Path $LogFile -Value ""
    return
}
    }
    else {
        Write-Log "Condiciones no cumplidas. El equipo permanecerá encendido."
        Write-Log "Razones: Inactividad=$IdleCondition, Red=$NetworkCondition"
        Write-ExecutionLog -IdleMinutes $IdleMinutes -NetworkKB $NetworkKB
        Write-Log "=== VERIFICACIÓN COMPLETADA (CONDICIONES NO CUMPLIDAS) ==="
        Add-ContentSafe -Path $LogFile -Value ""
    }
}
catch {
    Write-Log "Error durante la ejecución: $($_.Exception.Message)" "ERROR"
    Write-ExecutionLog -IdleMinutes 0 -NetworkKB 0
    Write-Log "=== VERIFICACIÓN COMPLETADA (ERROR GENERAL) ==="
    Add-ContentSafe -Path $LogFile -Value ""
}
finally {
    if ($ShouldCleanup) {
        Write-Log "Iniciando limpieza diaria de logs..."
        Clean-MainLogFile -FilePath $LogFile
        Clean-ExecutionLogFile -FilePath $LastRunFile
        Clean-NetworkHistory -FilePath $NetworkHistoryFile
        
        if (Test-WritePermissions -Path (Split-Path -Parent $LastCleanupFile)) {
            $cleanupTimestamp = (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")
            if (Add-ContentSafe -Path $LastCleanupFile -Value $cleanupTimestamp) {
                Write-Log "Limpieza diaria completada y registrada"
                Add-ContentSafe -Path $LogFile -Value ""
            }
        } else {
            Write-Log "No se puede escribir en ${LastCleanupFile} debido a permisos." "ERROR"
        }
    }
}

exit 0