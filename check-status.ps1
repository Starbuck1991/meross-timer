param(
    [string]$ServerUrl = "https://meross-timer.onrender.com"
)

Write-Host "📊 Verificando estado del servidor Render..." -ForegroundColor Cyan
Write-Host "🔗 $ServerUrl" -ForegroundColor Gray

try {
    $response = Invoke-RestMethod -Uri "$ServerUrl/status" -Method Get -TimeoutSec 30
    
    Write-Host "✅ Servidor activo:" -ForegroundColor Green
    Write-Host "   🟢 Disponible: $($response.scheduler_available)" -ForegroundColor Green
    Write-Host "   📱 Trabajos activos: $($response.active_jobs)" -ForegroundColor White
    Write-Host "   🕐 Hora España: $($response.spain_time)" -ForegroundColor White
    
    if ($response.api_version) {
        Write-Host "   🔧 Versión API: $($response.api_version)" -ForegroundColor Gray
    }
    
    if ($response.platform) {
        Write-Host "   🌐 Plataforma: $($response.platform)" -ForegroundColor Gray
    }
    
} catch {
    Write-Host "❌ Error conectando al servidor Render:" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)" -ForegroundColor White
    
    if ($_.Exception.Message -like "*timeout*") {
        Write-Host "   💡 El servicio puede estar 'dormido', intenta de nuevo" -ForegroundColor Yellow
    }
}
