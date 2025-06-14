param(
    [string]$ServerUrl = "https://meross-timer.onrender.com",
    [string]$ApiKey = $env:MEROSS_API_KEY
)

if (-not $ApiKey) {
    Write-Host "❌ Error: API Key requerida" -ForegroundColor Red
    exit 1
}

Write-Host "🔍 Probando conexión con API Real de Meross..." -ForegroundColor Cyan
Write-Host "🔗 $ServerUrl" -ForegroundColor Gray

$body = @{
    api_key = $ApiKey
} | ConvertTo-Json

try {
    Write-Host "📡 Enviando solicitud de prueba..." -ForegroundColor Yellow
    
    $response = Invoke-RestMethod -Uri "$ServerUrl/test-connection" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 45
    
    if ($response.status -eq "success") {
        Write-Host "✅ ¡Conexión exitosa!" -ForegroundColor Green
        Write-Host "   💬 $($response.message)" -ForegroundColor White
        Write-Host "   📱 Dispositivos encontrados: $($response.devices_found)" -ForegroundColor White
        
        if ($response.devices -and $response.devices.Count -gt 0) {
            Write-Host ""
            Write-Host "📋 Dispositivos disponibles:" -ForegroundColor Cyan
            foreach ($device in $response.devices) {
                $status = if ($device.online) { "🟢 Online" } else { "🔴 Offline" }
                Write-Host "   📱 $($device.name) ($($device.type)) - $status" -ForegroundColor White
            }
        }
        
    } else {
        Write-Host "❌ Error: $($response.message)" -ForegroundColor Red
    }
    
} catch {
    Write-Host "❌ Error de conexión: $($_.Exception.Message)" -ForegroundColor Red
    
    if ($_.Exception.Message -like "*timeout*") {
        Write-Host "💡 Render puede tardar en responder la primera vez" -ForegroundColor Yellow
    }
}
