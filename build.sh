#!/bin/bash
echo "🔄 Sincronizando archivos compartidos..."

# Crear directorios de destino si no existen
mkdir -p otra-carpeta/

# Copiar el archivo compartido
cp flex-launcher/assets/scripts/control-meross.ps1 otra-carpeta/control-meross.ps1

echo "✅ Archivos sincronizados correctamente"
echo "📂 Archivo copiado de: flex-launcher/assets/scripts/control-meross.ps1"
echo "📂 Archivo copiado a: otra-carpeta/control-meross.ps1"

# Verificar que el archivo se copió correctamente
if [ -f "otra-carpeta/control-meross.ps1" ]; then
    echo "✅ Verificación exitosa: El archivo existe en el destino"
else
    echo "❌ Error: El archivo no se copió correctamente"
    exit 1
fi

echo "🚀 Build completado. Iniciando aplicación..."