#!/bin/bash
echo "🔄 Sincronizando archivos compartidos..."

# Crear directorio de destino si no existe
mkdir -p flex-launcher/assets/scripts/

# Copiar el archivo de la raíz al subdirectorio
if [ -f "control-meross.ps1" ]; then
    cp control-meross.ps1 flex-launcher/assets/scripts/control-meross.ps1
    echo "✅ Archivo copiado: control-meross.ps1 → flex-launcher/assets/scripts/control-meross.ps1"
    
    # Verificar que el archivo se copió correctamente
    if [ -f "flex-launcher/assets/scripts/control-meross.ps1" ]; then
        echo "✅ Verificación exitosa: El archivo existe en el destino"
    else
        echo "❌ Error: El archivo no se copió correctamente"
        exit 1
    fi
else
    echo "❌ Archivo fuente no encontrado en la raíz: control-meross.ps1"
    exit 1
fi

echo "✅ Sincronización completada"