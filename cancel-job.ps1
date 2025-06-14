param(
    [Parameter(Mandatory=$true)]
    [string]$JobId,
    
    [string]$ApiKey = $env:MEROSS_API_KEY
)

if (-not $ApiKey) {
    Write-Host "❌ Error: Variable de entorno MEROSS_API_KEY no configurada" -ForegroundColor Red
    Write-Host "💡 Configúrala con: `$env:MEROSS_API_KEY = 'tu_clave_aqui'" -ForegroundColor Yellow
    exit 1
}

Write-Host "🚫 Cancelando trabajo..." -ForegroundColor Cyan
Write-Host "🆔 Job ID: $JobId" -ForegroundColor White
Write-Host ""

# 🔄 CAMBIO: Usar /cancel-job en lugar de /cancel
$url = 'https://meross-timer.onrender.com/cancel-job'

$body = @{
    job_id = $JobId
    api_key = $ApiKey
} | ConvertTo-Json

$headers = @{
    'Content-Type' = 'application/json'
}

try {
    Write-Host "📡 Enviando solicitud de cancelación..." -ForegroundColor Yellow
    
    $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -Headers $headers
    
    if ($response.status -eq "success") {
        Write-Host "✅ ¡Trabajo cancelado exitosamente!" -ForegroundColor Green
        Write-Host ""
        Write-Host "📋 Detalles:" -ForegroundColor Cyan
        Write-Host "   🆔 Job ID: $JobId" -ForegroundColor White
        Write-Host "   💬 $($response.message)" -ForegroundColor White
        
        Write-Host ""
        Write-Host "💡 Comando útil:" -ForegroundColor Cyan
        Write-Host "   • Ver trabajos restantes: .\check-status.ps1" -ForegroundColor White
        
    } else {
        Write-Host "❌ Error del servidor: $($response.message)" -ForegroundColor Red
    }
    
} catch {
    Write-Host "💥 Error de conexión:" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)" -ForegroundColor White
    
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode
        Write-Host "   Código de estado: $statusCode" -ForegroundColor Yellow
        
        try {
            $errorBody = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorBody)
            $errorText = $reader.ReadToEnd()
            if ($errorText) {
                $errorJson = $errorText | ConvertFrom-Json
                Write-Host "   Error del servidor: $($errorJson.message)" -ForegroundColor Red
            }
        } catch {
            # Ignorar errores al leer el cuerpo de la respuesta
        }
    }
}

Write-Host ""
