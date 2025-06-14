param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("status", "test", "on", "off", "timer-on", "timer-off", "jobs", "cancel", "help")]
    [string]$Action,
    
    [Parameter(Position=1)]
    [string]$Device = "KodiPlex",
    
    [Parameter(Position=2)]
    [int]$Minutes = 0,
    
    [string]$JobId,
    
    [string]$ServerUrl = "https://meross-timer.onrender.com",
    
    [string]$ApiKey = $env:MEROSS_API_KEY
)

# Colores para output
function Write-Success { param($msg) Write-Host $msg -ForegroundColor Green }
function Write-Error { param($msg) Write-Host $msg -ForegroundColor Red }
function Write-Info { param($msg) Write-Host $msg -ForegroundColor Cyan }
function Write-Warning { param($msg) Write-Host $msg -ForegroundColor Yellow }

# Función para mostrar ayuda
function Show-Help {
    Write-Host @"
🔌 MEROSS CONTROL - Script Unificado
====================================

USO:
  .\meross-control.ps1 <accion> [dispositivo] [minutos] [opciones]

ACCIONES DISPONIBLES:
  status                    - Ver estado del servicio
  test                      - Probar conexión y listar dispositivos
  on <dispositivo>          - Encender dispositivo inmediatamente
  off <dispositivo>         - Apagar dispositivo inmediatamente  
  timer-on <dispositivo> <minutos>   - Encender dispositivo en X minutos
  timer-off <dispositivo> <minutos>  - Apagar dispositivo en X minutos
  jobs                      - Ver trabajos activos
  cancel -JobId <id>        - Cancelar trabajo específico
  help                      - Mostrar esta ayuda

EJEMPLOS:
  .\meross-control.ps1 status
  .\meross-control.ps1 test
  .\meross-control.ps1 on KodiPlex
  .\meross-control.ps1 off HTPC
  .\meross-control.ps1 timer-off KodiPlex 30
  .\meross-control.ps1 timer-on Ambientador 60
  .\meross-control.ps1 jobs
  .\meross-control.ps1 cancel -JobId "KodiPlex_off_20250614_150000"

DISPOSITIVOS DISPONIBLES:
  - KodiPlex
  - HTPC  
  - Ambientador

NOTAS:
  - Variable de entorno MEROSS_API_KEY debe estar configurada
  - Los tiempos están en minutos
  - Usar comillas si el nombre del dispositivo tiene espacios
"@ -ForegroundColor White
}

# Validar API Key para acciones que la requieren
function Test-ApiKey {
    if (-not $ApiKey -and $Action -in @("on", "off", "timer-on", "timer-off", "cancel")) {
        Write-Error "❌ API Key requerida. Configure MEROSS_API_KEY o use -ApiKey"
        Write-Warning "💡 Ejemplo: `$env:MEROSS_API_KEY = 'tu_clave_aqui'"
        exit 1
    }
}

# Función para hacer requests HTTP
function Invoke-MerossApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Body = $null,
        [int]$TimeoutSec = 45
    )
    
    try {
        $uri = "$ServerUrl$Endpoint"
        Write-Info "📡 $Method $uri"
        
        $params = @{
            Uri = $uri
            Method = $Method
            TimeoutSec = $TimeoutSec
        }
        
        if ($Body) {
            $params.Body = ($Body | ConvertTo-Json)
            $params.ContentType = "application/json"
        }
        
        return Invoke-RestMethod @params
    }
    catch {
        Write-Error "❌ Error de conexión: $($_.Exception.Message)"
        if ($_.Exception.Message -like "*timeout*") {
            Write-Warning "💡 Render puede tardar en responder la primera vez"
        }
        exit 1
    }
}

# Función para mostrar dispositivos
function Show-Devices {
    param($devices)
    
    if ($devices -and $devices.Count -gt 0) {
        Write-Info "`n📋 Dispositivos disponibles:"
        foreach ($device in $devices) {
            $status = if ($device.online) { "🟢 Online" } else { "🔴 Offline" }
            $state = if ($device.state -eq "on") { "🔌 Encendido" } else { "⚫ Apagado" }
            Write-Host "   📱 $($device.name) ($($device.type)) - $status - $state" -ForegroundColor White
        }
    }
}

# Función para mostrar trabajos
function Show-Jobs {
    param($jobs)
    
    if ($jobs -and $jobs.Count -gt 0) {
        Write-Info "`n⏰ Trabajos activos:"
        foreach ($job in $jobs) {
            $status_icon = switch ($job.status) {
                "waiting" { "⏳" }
                "executing" { "🚀" }
                "completed" { "✅" }
                "error" { "❌" }
                default { "❓" }
            }
            
            Write-Host "   $status_icon [$($job.id)] $($job.name)" -ForegroundColor White
            Write-Host "      ⏰ Ejecutar: $($job.execution_time_spain)" -ForegroundColor Gray
            Write-Host "      ⏱️  Faltan: $($job.remaining_minutes) min $($job.remaining_seconds % 60) seg" -ForegroundColor Gray
            
            if ($job.result) {
                Write-Host "      ✅ Resultado: $($job.result.message)" -ForegroundColor Green
            }
            if ($job.error) {
                Write-Host "      ❌ Error: $($job.error)" -ForegroundColor Red
            }
        }
    } else {
        Write-Info "📭 No hay trabajos activos"
    }
}

# MAIN SCRIPT
Write-Host "🔌 MEROSS CONTROL v1.0" -ForegroundColor Magenta
Write-Host "🔗 $ServerUrl" -ForegroundColor Gray

switch ($Action) {
    "help" {
        Show-Help
        exit 0
    }
    
    "status" {
        Write-Info "📊 Consultando estado del servicio..."
        $response = Invoke-MerossApi -Endpoint "/status"
        
        Write-Success "✅ Servicio activo"
        Write-Host "   🕐 Hora España: $($response.spain_time)" -ForegroundColor White
        Write-Host "   📊 Trabajos activos: $($response.active_jobs)" -ForegroundColor White
        Write-Host "   🖥️  Plataforma: $($response.platform)" -ForegroundColor White
    }
    
    "test" {
        Write-Info "🧪 Probando conexión con API de Meross..."
        
        $body = if ($ApiKey) { @{ api_key = $ApiKey } } else { $null }
        $method = if ($ApiKey) { "POST" } else { "GET" }
        
        $response = Invoke-MerossApi -Endpoint "/test-connection" -Method $method -Body $body
        
        if ($response.status -eq "success") {
            Write-Success "✅ ¡Conexión exitosa!"
            Write-Host "   💬 $($response.message)" -ForegroundColor White
            Write-Host "   📱 Dispositivos encontrados: $($response.devices_found)" -ForegroundColor White
            Show-Devices $response.devices
        } else {
            Write-Error "❌ Error: $($response.message)"
        }
    }
    
    "on" {
        Test-ApiKey
        Write-Info "🔌 Encendiendo $Device..."
        
        $response = Invoke-MerossApi -Endpoint "/timer" -Method "POST" -Body @{
            device_name = $Device
            action = "on"
            minutes = 0
            api_key = $ApiKey
        }
        
        if ($response.status -eq "success") {
            Write-Success "✅ $($response.message)"
            Write-Host "   🆔 Job ID: $($response.job_id)" -ForegroundColor Gray
        } else {
            Write-Error "❌ Error: $($response.message)"
        }
    }
    
    "off" {
        Test-ApiKey
        Write-Info "⚫ Apagando $Device..."
        
        $response = Invoke-MerossApi -Endpoint "/timer" -Method "POST" -Body @{
            device_name = $Device
            action = "off"
            minutes = 0
            api_key = $ApiKey
        }
        
        if ($response.status -eq "success") {
            Write-Success "✅ $($response.message)"
            Write-Host "   🆔 Job ID: $($response.job_id)" -ForegroundColor Gray
        } else {
            Write-Error "❌ Error: $($response.message)"
        }
    }
    
    "timer-on" {
        Test-ApiKey
        if ($Minutes -le 0) {
            Write-Error "❌ Debe especificar minutos > 0"
            Write-Warning "💡 Ejemplo: .\meross-control.ps1 timer-on KodiPlex 30"
            exit 1
        }
        
        Write-Info "⏰ Programando encendido de $Device en $Minutes minutos..."
        
        $response = Invoke-MerossApi -Endpoint "/timer" -Method "POST" -Body @{
            device_name = $Device
            action = "on"
            minutes = $Minutes
            api_key = $ApiKey
        }
        
        if ($response.status -eq "success") {
            Write-Success "✅ $($response.message)"
            Write-Host "   🕐 Se ejecutará: $($response.execution_time_spain)" -ForegroundColor White
            Write-Host "   🆔 Job ID: $($response.job_id)" -ForegroundColor Gray
        } else {
            Write-Error "❌ Error: $($response.message)"
        }
    }
    
    "timer-off" {
        Test-ApiKey
        if ($Minutes -le 0) {
            Write-Error "❌ Debe especificar minutos > 0"
            Write-Warning "💡 Ejemplo: .\meross-control.ps1 timer-off KodiPlex 30"
            exit 1
        }
        
        Write-Info "⏰ Programando apagado de $Device en $Minutes minutos..."
        
        $response = Invoke-MerossApi -Endpoint "/timer" -Method "POST" -Body @{
            device_name = $Device
            action = "off"
            minutes = $Minutes
            api_key = $ApiKey
        }
        
        if ($response.status -eq "success") {
            Write-Success "✅ $($response.message)"
            Write-Host "   🕐 Se ejecutará: $($response.execution_time_spain)" -ForegroundColor White
            Write-Host "   🆔 Job ID: $($response.job_id)" -ForegroundColor Gray
        } else {
            Write-Error "❌ Error: $($response.message)"
        }
    }
    
    "jobs" {
        Write-Info "📋 Consultando trabajos activos..."
        
        $response = Invoke-MerossApi -Endpoint "/jobs"
        
        if ($response.status -eq "success") {
            Write-Success "✅ Consulta exitosa"
            Write-Host "   🕐 Hora España: $($response.spain_time)" -ForegroundColor White
            Write-Host "   📊 Total trabajos: $($response.active_jobs)" -ForegroundColor White
            Show-Jobs $response.jobs
        } else {
            Write-Error "❌ Error: $($response.message)"
        }
    }
    
    "cancel" {
        Test-ApiKey
        if (-not $JobId) {
            Write-Error "❌ Debe especificar -JobId"
            Write-Warning "💡 Ejemplo: .\meross-control.ps1 cancel -JobId 'KodiPlex_off_20250614_150000'"
            exit 1
        }
        
        Write-Info "❌ Cancelando trabajo $JobId..."
        
        $response = Invoke-MerossApi -Endpoint "/cancel-job" -Method "POST" -Body @{
            job_id = $JobId
            api_key = $ApiKey
        }
        
        if ($response.status -eq "success") {
            Write-Success "✅ $($response.message)"
        } else {
            Write-Error "❌ Error: $($response.message)"
        }
    }
    
    default {
        Write-Error "❌ Acción no válida: $Action"
        Write-Warning "💡 Use: .\meross-control.ps1 help"
        exit 1
    }
}
