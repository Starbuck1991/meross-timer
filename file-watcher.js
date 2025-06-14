const fs = require("fs");
const path = require("path");

// ⚠️ CAMBIA ESTAS RUTAS POR LAS TUYAS:
const archivoOriginal = "./control-meross.ps1"; // ← Pon aquí tu archivo
const carpetaDestino = "./flex-launcher/assets/scripts/"; // ← Pon aquí tu carpeta

// No toques nada de aquí para abajo
const archivoDestino = path.join(
  carpetaDestino,
  path.basename(archivoOriginal)
);

// Crear carpeta si no existe
if (!fs.existsSync(carpetaDestino)) {
  fs.mkdirSync(carpetaDestino, { recursive: true });
}

// Función para copiar
function copiarArchivo() {
  try {
    fs.copyFileSync(archivoOriginal, archivoDestino);
    console.log(`✅ Copiado: ${archivoOriginal} → ${archivoDestino}`);
  } catch (error) {
    console.error("❌ Error:", error.message);
  }
}

// Copiar al inicio
copiarArchivo();

// Vigilar cambios
fs.watchFile(archivoOriginal, () => {
  console.log(`📝 Cambio detectado...`);
  copiarArchivo();
});

console.log(`👀 Vigilando: ${archivoOriginal}`);
console.log("💡 Edita el archivo y verás como se copia automáticamente");
console.log("🛑 Presiona Ctrl+C para parar");

// Parar limpiamente
process.on("SIGINT", () => {
  fs.unwatchFile(archivoOriginal);
  console.log("\n👋 ¡Hasta luego!");
  process.exit(0);
});
