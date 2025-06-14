const fs = require("fs");
const path = require("path");

// Configuración para tu proyecto
const archivoOriginal = "./control-meross.ps1";
const carpetaDestino = "./flex-launcher/assets/scripts/";

const archivoDestino = path.join(
  carpetaDestino,
  path.basename(archivoOriginal)
);

// Función para escribir logs
function escribirLog(mensaje) {
  const logFile = path.join(carpetaDestino, "watcher.log");
  const timestamp = new Date().toISOString();
  const logMessage = `${timestamp} - ${mensaje}\n`;

  try {
    fs.appendFileSync(logFile, logMessage);
  } catch (error) {
    // Si no puede escribir el log, continúa silenciosamente
  }
}

// Crear carpeta si no existe
try {
  if (!fs.existsSync(carpetaDestino)) {
    fs.mkdirSync(carpetaDestino, { recursive: true });
    escribirLog("Carpeta destino creada");
  }
} catch (error) {
  escribirLog(`Error creando carpeta: ${error.message}`);
  process.exit(1);
}

// Función para copiar archivo
function copiarArchivo() {
  try {
    if (fs.existsSync(archivoOriginal)) {
      fs.copyFileSync(archivoOriginal, archivoDestino);
      escribirLog(`Archivo copiado: ${path.basename(archivoOriginal)}`);
    } else {
      escribirLog(`Archivo original no encontrado: ${archivoOriginal}`);
    }
  } catch (error) {
    escribirLog(`Error copiando archivo: ${error.message}`);
  }
}

// Copia inicial
copiarArchivo();
escribirLog("Watcher iniciado - vigilando cambios");

// Vigilar cambios en el archivo
fs.watchFile(archivoOriginal, (curr, prev) => {
  if (curr.mtime !== prev.mtime) {
    escribirLog("Cambio detectado");
    copiarArchivo();
  }
});

// Escribir un heartbeat cada 5 minutos para confirmar que está funcionando
setInterval(() => {
  escribirLog("Watcher activo");
}, 5 * 60 * 1000); // 5 minutos

// Manejar cierre del proceso
process.on("SIGINT", () => {
  fs.unwatchFile(archivoOriginal);
  escribirLog("Watcher detenido manualmente");
  process.exit(0);
});

process.on("SIGTERM", () => {
  fs.unwatchFile(archivoOriginal);
  escribirLog("Watcher detenido por sistema");
  process.exit(0);
});

// Manejar errores no capturados
process.on("uncaughtException", (error) => {
  escribirLog(`Error no capturado: ${error.message}`);
  process.exit(1);
});

process.on("unhandledRejection", (reason, promise) => {
  escribirLog(`Promesa rechazada: ${reason}`);
});
