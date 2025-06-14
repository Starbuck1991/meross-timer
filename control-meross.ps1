param(
    [Parameter(Mandatory=$true)]
    [string]$DeviceName,
    
    [Parameter(Mandatory=$true)]
    [int]$TimerMinutes,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet("on", "off")]
    [string]$Action,
    
    [string]$ApiKey = $env:MEROSS_API_KEY,
    
    # URL de Render (cambia por tu URL real)
    [string]$ServerUrl = "https://meross-timer.onrender.com"
)

# Validaciones mejoradas
if (-not $ApiKey) {
    Write-Host "❌ Error: Variable de entorno MEROSS_API_KEY no configurada" -ForegroundColor Red
    Write-Host "💡 Configúrala con: `$env:MEROSS_API_KEY = 'tu_clave_aqui'" -ForegroundColor Yellow
    Write-Host "📝 O pásala como parámetro: -ApiKey 'tu_clave'" -ForegroundColor Cyan
    exit 1
}

if ($TimerMinutes -lt 1) {
    Write-Host "❌ Error: El tiempo mínimo es 1 minuto" -ForegroundColor Red
    exit 1
}

if ($TimerMinutes -gt 1440) {
    Write-Host "❌ Error: El tiempo máximo es 1440 minutos (24 horas)" -ForegroundColor Red
    exit 1
}

# Mostrar información
Write-Host "🕐 Programando temporizador con API Real de Meross..." -ForegroundColor Cyan
Write-Host "🌐 Servidor Render: $ServerUrl" -ForegroundColor Gray
Write-Host "📱 Dispositivo: $DeviceName" -ForegroundColor White
Write-Host "⏱️  Tiempo: $TimerMinutes minutos" -ForegroundColor White
Write-Host "🔌 Acción: $Action" -ForegroundColor White

# Calcular tiempo de ejecución aproximado
$executionTime = (Get-Date).AddMinutes($TimerMinutes)
Write-Host "🕐 Se ejecutará aproximadamente: $($executionTime.ToString('HH:mm:ss dd/MM/yyyy'))" -ForegroundColor Yellow
Write-Host ""

# Preparar solicitud
$url = "$ServerUrl/timer"
$body = @{
    device_name = $DeviceName
    minutes = $TimerMinutes
    action = $Action
    api_key = $ApiKey
} | ConvertTo-Json

$headers = @{
    'Content-Type' = 'application/json'
    'User-Agent' = 'PowerShell-MerossTimer-Render/1.0'
}

try {
    Write-Host "📡 Enviando solicitud al servidor Render..." -ForegroundColor Yellow
    Write-Host "🔗 URL: $url" -ForegroundColor Gray
    
    # Timeout más largo para Render (puede tardar en despertar)
    $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -Headers $headers -TimeoutSec 60
    
    if ($response.status -eq "success") {
        Write-Host "✅ ¡Temporizador programado exitosamente!" -ForegroundColor Green
        Write-Host ""
        Write-Host "📋 Detalles:" -ForegroundColor Cyan
        Write-Host "   🆔 Job ID: $($response.job_id)" -ForegroundColor White
        
        if ($response.execution_time_spain) {
            Write-Host "   🕐 Se ejecutará: $($response.execution_time_spain)" -ForegroundColor White
        }
        
        Write-Host "   💬 $($response.message)" -ForegroundColor White
        
        if ($response.api_type) {
            Write-Host "   🔧 API: $($response.api_type)" -ForegroundColor Magenta
        }
        
        if ($response.platform) {
            Write-Host "   🌐 Plataforma: $($response.platform)" -ForegroundColor Gray
        }
        
        if ($response.note) {
            Write-Host "   📝 Nota: $($response.note)" -ForegroundColor Yellow
        }
        
        Write-Host ""
        Write-Host "💡 Comandos útiles:" -ForegroundColor Cyan
        Write-Host "   • Ver estado: .\check-status.ps1 -ServerUrl '$ServerUrl'" -ForegroundColor White
        Write-Host "   • Ver trabajos: .\list-jobs.ps1 -ServerUrl '$ServerUrl'" -ForegroundColor White
        Write-Host "   • Cancelar: .\cancel-job.ps1 -JobId '$($response.job_id)' -ServerUrl '$ServerUrl'" -ForegroundColor White
        Write-Host "   • Probar conexión: .\test-connection.ps1 -ServerUrl '$ServerUrl'" -ForegroundColor White
        
        # Guardar configuración para scripts auxiliares
        $config = @{
            last_job_id = $response.job_id
            server_url = $ServerUrl
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $config | ConvertTo-Json | Out-File -FilePath "meross-config.json" -Encoding UTF8
        
    } else {
        Write-Host "❌ Error del servidor: $($response.message)" -ForegroundColor Red
        if ($response.error) {
            Write-Host "   Detalles: $($response.error)" -ForegroundColor Yellow
        }
        exit 1
    }
    
} catch {
    Write-Host "💥 Error de conexión:" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)" -ForegroundColor White
    
    # Manejo específico para Render
    if ($_.Exception.Message -like "*timeout*") {
        Write-Host ""
        Write-Host "⏰ Timeout detectado - Posibles causas:" -ForegroundColor Yellow
        Write-Host "   • El servicio de Render está 'dormido' y tardó en despertar" -ForegroundColor Cyan
        Write-Host "   • Intenta de nuevo en unos segundos" -ForegroundColor Cyan
        Write-Host "   • Render puede tardar hasta 30s en responder la primera vez" -ForegroundColor Cyan
    }
    
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
        Write-Host "   Código HTTP: $statusCode" -ForegroundColor Yellow
        
        # Mensajes específicos según código de error
        switch ($statusCode) {
            400 { Write-Host "   💡 Verifica los parámetros enviados" -ForegroundColor Cyan }
            401 { Write-Host "   💡 Verifica tu API Key" -ForegroundColor Cyan }
            404 { 
                Write-Host "   💡 Verifica la URL del servidor Render" -ForegroundColor Cyan 
                Write-Host "   💡 ¿Está correcta la URL? $ServerUrl" -ForegroundColor Yellow
            }
            500 { Write-Host "   💡 Error interno del servidor" -ForegroundColor Cyan }
            503 { 
                Write-Host "   💡 Servidor temporalmente no disponible" -ForegroundColor Cyan 
                Write-Host "   💡 Render puede estar reiniciando el servicio" -ForegroundColor Yellow
            }
        }
        
        try {
            $errorBody = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorBody)
            $errorText = $reader.ReadToEnd()
            $reader.Close()
            
            if ($errorText) {
                $errorJson = $errorText | ConvertFrom-Json
                if ($errorJson.message) {
                    Write-Host "   Error del servidor: $($errorJson.message)" -ForegroundColor Red
                }
                if ($errorJson.error) {
                    Write-Host "   Detalles: $($errorJson.error)" -ForegroundColor Yellow
                }
            }
        } catch {
            # Ignorar errores al leer el cuerpo de la respuesta
        }
    }
    
    Write-Host ""
    Write-Host "🔧 Soluciones para Render:" -ForegroundColor Cyan
    Write-Host "   • Verifica que la URL de Render sea correcta" -ForegroundColor White
    Write-Host "   • Espera 30-60 segundos si el servicio estaba dormido" -ForegroundColor White
    Write-Host "   • Prueba con: .\test-connection.ps1 -ServerUrl '$ServerUrl'" -ForegroundColor White
    Write-Host "   • Verifica los logs en el dashboard de Render" -ForegroundColor White
    
    exit 1
}

Write-Host ""
