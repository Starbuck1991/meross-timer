import asyncio
import os
import threading
import time
from datetime import datetime, timedelta
import pytz
from flask import Flask, request, jsonify
from meross_iot.http_api import MerossHttpClient
from meross_iot.manager import MerossManager

app = Flask(__name__)

# Configurar timezone de España
SPAIN_TZ = pytz.timezone('Europe/Madrid')

# Diccionario para trackear tareas activas
active_tasks = {}

def log_message(message):
    timestamp = datetime.now(SPAIN_TZ).strftime("%Y-%m-%d %H:%M:%S %Z")
    print(f"[{timestamp}] {message}", flush=True)

async def control_device_meross_iot(email, password, device_name, action, job_id, max_retries=3):
    """Control usando meross-iot (la librería que sabemos que funciona)"""
    for attempt in range(max_retries):
        http_api_client = None
        manager = None
        
        try:
            log_message(f"🔧 [{job_id}] Intento {attempt + 1}/{max_retries} - Controlando {device_name} -> {action}")
            
            # Conectar con meross-iot - API corregida para v0.4.9.0
            http_api_client = await MerossHttpClient.async_from_user_password(
                api_base_url='https://iotx-eu.meross.com',
                email=email, 
                password=password
            )
            log_message(f"✅ [{job_id}] Login exitoso con meross-iot")
            
            # Manager
            manager = MerossManager(http_client=http_api_client)
            await manager.async_init()
            log_message(f"✅ [{job_id}] Manager inicializado")

            # Descubrir dispositivos
            await manager.async_device_discovery()
            devices = manager.find_devices(device_name=device_name)
            
            if not devices:
                all_devices = manager.find_devices()
                available = [d.name for d in all_devices]
                return {
                    "status": "error", 
                    "message": f"Dispositivo '{device_name}' no encontrado. Disponibles: {available}"
                }
                
            device = devices[0]
            log_message(f"✅ [{job_id}] Dispositivo encontrado: {device.name}")
            
            # Actualizar estado del dispositivo
            await device.async_update()
            current_state = device.is_on()
            log_message(f"📊 [{job_id}] Estado actual: {'🟢 ENCENDIDO' if current_state else '🔴 APAGADO'}")
            
            # Ejecutar acción
            if action.lower() == 'off':
                await device.async_turn_off()
                log_message(f"🔌 [{job_id}] {device.name} APAGADO")
            elif action.lower() == 'on':
                await device.async_turn_on()
                log_message(f"🔌 [{job_id}] {device.name} ENCENDIDO")
            
            # Verificar resultado
            await asyncio.sleep(2)
            await device.async_update()
            new_state = device.is_on()
            log_message(f"✅ [{job_id}] Nuevo estado: {'🟢 ENCENDIDO' if new_state else '🔴 APAGADO'}")
            
            return {
                "status": "success", 
                "message": f"Acción '{action}' ejecutada en {device.name}",
                "previous_state": "on" if current_state else "off",
                "new_state": "on" if new_state else "off"
            }
            
        except Exception as e:
            log_message(f"💥 [{job_id}] Error en intento {attempt + 1}: {str(e)}")
            if attempt < max_retries - 1:
                wait_time = (attempt + 1) * 15
                log_message(f"⏳ [{job_id}] Esperando {wait_time} segundos antes del siguiente intento...")
                await asyncio.sleep(wait_time)
            else:
                return {"status": "error", "message": f"Error después de {max_retries} intentos: {str(e)}"}
                
        finally:
            if manager:
                manager.close()
            if http_api_client:
                await http_api_client.async_logout()

def execute_delayed_task(email, password, device_name, action, minutes, job_id):
    """Función que se ejecuta en un hilo separado con sleep"""
    try:
        # Marcar como activa
        start_time = datetime.now(SPAIN_TZ)
        execution_time = start_time + timedelta(minutes=minutes)
        active_tasks[job_id] = {
            "device_name": device_name,
            "action": action,
            "start_time": start_time.isoformat(),
            "execution_time": execution_time.isoformat(),
            "status": "waiting"
        }
        
        log_message(f"⏰ [{job_id}] Esperando {minutes} minutos...")
        log_message(f"🕐 [{job_id}] Se ejecutará a las: {execution_time.strftime('%H:%M:%S')}")
        
        # SLEEP - aquí es donde pausamos
        time.sleep(minutes * 60)
        
        # Verificar si la tarea fue cancelada durante el sleep
        if job_id not in active_tasks:
            log_message(f"❌ [{job_id}] Tarea cancelada durante la espera")
            return
        
        # Actualizar estado
        active_tasks[job_id]["status"] = "executing"
        log_message(f"🚀 [{job_id}] ¡Tiempo cumplido! Ejecutando acción...")
        
        # Ejecutar la acción con meross-iot
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            result = loop.run_until_complete(
                control_device_meross_iot(email, password, device_name, action, job_id)
            )
            log_message(f"🎯 [{job_id}] Resultado: {result}")
            
            # Actualizar estado final
            active_tasks[job_id]["status"] = "completed"
            active_tasks[job_id]["result"] = result
        finally:
            loop.close()
        
        # Limpiar después de 5 minutos
        time.sleep(300)  # 5 minutos
        if job_id in active_tasks:
            del active_tasks[job_id]
            log_message(f"🧹 [{job_id}] Tarea limpiada del registro")
            
    except Exception as e:
        log_message(f"💥 [{job_id}] Error crítico: {str(e)}")
        if job_id in active_tasks:
            active_tasks[job_id]["status"] = "error"
            active_tasks[job_id]["error"] = str(e)

# ===== ENDPOINTS =====

@app.route('/', methods=['GET'])
def health_check():
    """Health check endpoint para Render"""
    return jsonify({
        "status": "healthy",
        "service": "Meross Timer API - meross-iot",
        "platform": "render",
        "timestamp": datetime.now(SPAIN_TZ).isoformat(),
        "features": [
            "meross-iot library integration",
            "Timer scheduling",
            "Job management",
            "Spain timezone support"
        ]
    })

@app.route('/status', methods=['GET'])
def get_status():
    try:
        now_spain = datetime.now(SPAIN_TZ)
        return jsonify({
            "scheduler_available": True,
            "active_jobs": len(active_tasks),
            "spain_time": now_spain.strftime('%H:%M:%S %d/%m/%Y %Z'),
            "timestamp": now_spain.isoformat(),
            "system": "Render deployment",
            "platform": "render"
        })
    except Exception as e:
        return jsonify({
            "scheduler_available": False,
            "active_jobs": 0,
            "error": str(e)
        }), 500

@app.route('/jobs', methods=['GET'])
def get_jobs():
    try:
        now_spain = datetime.now(SPAIN_TZ)
        jobs_info = []
        
        for job_id, task in active_tasks.items():
            try:
                execution_time = datetime.fromisoformat(task['execution_time'])
                execution_time_spain = execution_time.strftime('%H:%M:%S %d/%m/%Y')
                
                time_remaining = execution_time - now_spain
                remaining_seconds = max(0, int(time_remaining.total_seconds()))
                remaining_minutes = remaining_seconds // 60
                
                job_info = {
                    "id": job_id,
                    "name": f"Control {task['device_name']} -> {task['action']}",
                    "execution_time": task['execution_time'],
                    "execution_time_spain": execution_time_spain,
                    "status": task.get('status', 'unknown'),
                    "remaining_minutes": remaining_minutes,
                    "remaining_seconds": remaining_seconds
                }
                
                if task.get('status') == "completed" and 'result' in task:
                    job_info['result'] = task['result']
                elif task.get('status') == "error" and 'error' in task:
                    job_info['error'] = task['error']
                
                jobs_info.append(job_info)
                
            except Exception as e:
                log_message(f"❌ Error procesando job {job_id}: {str(e)}")
        
        return jsonify({
            "status": "success",
            "active_jobs": len(active_tasks),
            "jobs": jobs_info,
            "spain_time": now_spain.strftime('%H:%M:%S %d/%m/%Y %Z'),
            "timestamp": now_spain.isoformat()
        })
        
    except Exception as e:
        log_message(f"💥 Error en /jobs: {str(e)}")
        return jsonify({
            "status": "error",
            "message": str(e),
            "active_jobs": len(active_tasks) if 'active_tasks' in globals() else 0
        }), 500

@app.route('/timer', methods=['POST'])
def set_timer():
    try:
        data = request.get_json()
        
        email = os.getenv('MEROSS_EMAIL')
        password = os.getenv('MEROSS_PASSWORD')
        api_key_env = os.getenv('MEROSS_API_KEY')
        
        device_name = data.get('device_name')
        minutes = int(data.get('minutes', 1))
        action = data.get('action', 'off')
        api_key = data.get('api_key')
        
        # Validaciones
        if not all([email, password, device_name]):
            return jsonify({"status": "error", "message": "Faltan parámetros requeridos"}), 400
        
        # Solo validar API key si está configurada
        if api_key_env and api_key != api_key_env:
            return jsonify({"status": "error", "message": "Clave API inválida"}), 401
        
        if minutes < 0:
            return jsonify({"status": "error", "message": "El tiempo mínimo es 0 minutos"}), 400
        
        if minutes > 1440:  # 24 horas
            return jsonify({"status": "error", "message": "El tiempo máximo es 1440 minutos (24 horas)"}), 400
        
        # Crear ID único
        now = datetime.now(SPAIN_TZ)
        job_id = f"{device_name}_{action}_{now.strftime('%Y%m%d_%H%M%S')}"
        
        log_message(f"🕐 Programando: {device_name} -> {action} en {minutes} minutos")
        
        # Ejecutar en hilo separado para no bloquear la respuesta HTTP
        thread = threading.Thread(
            target=execute_delayed_task,
            args=(email, password, device_name, action, minutes, job_id),
            daemon=True
        )
        thread.start()
        
        execution_time = now + timedelta(minutes=minutes)
        
        return jsonify({
            "status": "success",
            "message": f"Programado {action} en {device_name} después de {minutes} minutos",
            "job_id": job_id,
            "execution_time": execution_time.isoformat(),
            "execution_time_spain": execution_time.strftime('%H:%M:%S %d/%m/%Y'),
            "platform": "render"
        })
        
    except Exception as e:
        log_message(f"💥 Error: {str(e)}")
        return jsonify({"status": "error", "message": str(e)}), 500

# ===== ENDPOINTS SIMPLIFICADOS =====

@app.route('/kodiplex/off/<int:minutes>', methods=['GET'])
def kodiplex_off_quick(minutes):
    """Atajo rápido: GET /kodiplex/off/30"""
    try:
        email = os.getenv('MEROSS_EMAIL')
        password = os.getenv('MEROSS_PASSWORD')
        
        if not email or not password:
            return jsonify({"error": "Variables de entorno no configuradas"}), 500
        
        now = datetime.now(SPAIN_TZ)
        job_id = f"KodiPlex_off_{now.strftime('%Y%m%d_%H%M%S')}"
        
        thread = threading.Thread(
            target=execute_delayed_task,
            args=(email, password, "KodiPlex", "off", minutes, job_id),
            daemon=True
        )
        thread.start()
        
        execution_time = now + timedelta(minutes=minutes)
        
        return jsonify({
            "message": f"🔌 KodiPlex se apagará en {minutes} minutos",
            "job_id": job_id,
            "execution_time_spain": execution_time.strftime('%H:%M:%S %d/%m/%Y'),
            "current_time": now.strftime('%H:%M:%S')
        })
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/kodiplex/on/<int:minutes>', methods=['GET'])
def kodiplex_on_quick(minutes):
    """Atajo rápido: GET /kodiplex/on/30"""
    try:
        email = os.getenv('MEROSS_EMAIL')
        password = os.getenv('MEROSS_PASSWORD')
        
        if not email or not password:
            return jsonify({"error": "Variables de entorno no configuradas"}), 500
        
        now = datetime.now(SPAIN_TZ)
        job_id = f"KodiPlex_on_{now.strftime('%Y%m%d_%H%M%S')}"
        
        thread = threading.Thread(
            target=execute_delayed_task,
            args=(email, password, "KodiPlex", "on", minutes, job_id),
            daemon=True
        )
        thread.start()
        
        execution_time = now + timedelta(minutes=minutes)
        
        return jsonify({
            "message": f"🔌 KodiPlex se encenderá en {minutes} minutos",
            "job_id": job_id,
            "execution_time_spain": execution_time.strftime('%H:%M:%S %d/%m/%Y'),
            "current_time": now.strftime('%H:%M:%S')
        })
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/cancel-job', methods=['POST'])
def cancel_job():
    try:
        data = request.get_json()
        job_id = data.get('job_id')
        api_key = data.get('api_key')
        api_key_env = os.getenv('MEROSS_API_KEY')
        
        if not job_id:
            return jsonify({"status": "error", "message": "job_id es requerido"}), 400
        
        # Solo validar API key si está configurada
        if api_key_env and api_key != api_key_env:
            return jsonify({"status": "error", "message": "Clave API inválida"}), 401
        
        if job_id in active_tasks:
            task_status = active_tasks[job_id].get("status", "unknown")
            if task_status == "waiting":
                del active_tasks[job_id]
                log_message(f"✅ Job cancelado: {job_id}")
                return jsonify({
                    "status": "success",
                    "message": f"Job {job_id} cancelado exitosamente"
                })
            else:
                return jsonify({
                    "status": "error",
                    "message": f"Job {job_id} está en estado '{task_status}', no se puede cancelar"
                }), 400
        else:
            return jsonify({
                "status": "error",
                "message": f"Job {job_id} no encontrado"
            }), 404
            
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/test-connection', methods=['GET', 'POST'])
def test_connection():
    """Probar conexión con Meross"""
    try:
        log_message("🧪 Iniciando test-connection endpoint")
        
        # Si es POST, verificar API key
        if request.method == 'POST':
            data = request.get_json() or {}
            api_key = data.get('api_key')
            api_key_env = os.getenv('MEROSS_API_KEY')
            
            log_message(f"🔑 API Key recibida: {'SÍ' if api_key else 'NO'}")
            
            if api_key_env and api_key != api_key_env:
                log_message("❌ API Key inválida")
                return jsonify({"status": "error", "message": "Clave API inválida"}), 401

        email = os.getenv('MEROSS_EMAIL')
        password = os.getenv('MEROSS_PASSWORD')
        
        log_message(f"📧 Email configurado: {'SÍ' if email else 'NO'}")
        log_message(f"🔐 Password configurado: {'SÍ' if password else 'NO'}")
        
        if not email or not password:
            log_message("❌ Variables de entorno faltantes")
            return jsonify({
                "status": "error",
                "message": "Variables de entorno MEROSS_EMAIL o MEROSS_PASSWORD no configuradas"
            }), 500

        # Crear job_id temporal para logs
        test_job_id = f"test_connection_{datetime.now(SPAIN_TZ).strftime('%H%M%S')}"
        log_message(f"🆔 Job ID creado: {test_job_id}")

        # Ejecutar test en un hilo separado para no bloquear
        def test_async():
            try:
                log_message("🔄 Iniciando loop asyncio")
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                try:
                    result = loop.run_until_complete(test_meross_connection(email, password, test_job_id))
                    log_message(f"✅ Resultado obtenido: {result.get('status', 'unknown')}")
                    return result
                finally:
                    loop.close()
                    log_message("🔄 Loop asyncio cerrado")
            except Exception as e:
                log_message(f"💥 Error en test_async: {str(e)}")
                return {"status": "error", "message": f"Error interno: {str(e)}"}

        log_message("🚀 Ejecutando test asíncrono")
        result = test_async()
        log_message(f"📤 Enviando respuesta: {result}")
        
        return jsonify(result)
        
    except Exception as e:
        log_message(f"💥 Error crítico en test_connection: {str(e)}")
        return jsonify({"status": "error", "message": str(e)}), 500

async def test_meross_connection(email, password, job_id):
    """Test de conexión asíncrono"""
    http_api_client = None
    manager = None
    
    try:
        log_message(f"🧪 [{job_id}] Probando conexión con Meross...")
        
        # Conectar - API corregida para v0.4.9.0
        http_api_client = await MerossHttpClient.async_from_user_password(
            api_base_url='https://iotx-eu.meross.com',
            email=email, 
            password=password
        )
        log_message(f"✅ [{job_id}] Login exitoso")
        
        # Manager
        manager = MerossManager(http_client=http_api_client)
        await manager.async_init()
        log_message(f"✅ [{job_id}] Manager inicializado")
        
        # Descubrir dispositivos
        await manager.async_device_discovery()
        devices = manager.find_devices()
        
        device_list = []
        for device in devices:
            try:
                await device.async_update()
                # Convertir OnlineStatus a boolean
                online_status = getattr(device, 'online_status', None)
                is_online = online_status.value == 1 if online_status else True
                
                device_list.append({
                    "name": device.name,
                    "type": str(device.type),
                    "online": is_online,
                    "state": "on" if hasattr(device, 'is_on') and device.is_on() else "off"
                })
            except Exception as e:
                log_message(f"⚠️ [{job_id}] Error procesando dispositivo {device.name}: {str(e)}")
                device_list.append({
                    "name": device.name,
                    "type": str(device.type),
                    "online": False,
                    "state": "unknown"
                })
        
        log_message(f"✅ [{job_id}] {len(devices)} dispositivos encontrados")
        
        return {
            "status": "success",
            "message": "Conexión exitosa con meross-iot",
            "devices_found": len(devices),
            "devices": device_list
        }
        
    except Exception as e:
        log_message(f"💥 [{job_id}] Error en test: {str(e)}")
        return {
            "status": "error",
            "message": f"Error de conexión: {str(e)}"
        }
    finally:
        if manager:
            manager.close()
        if http_api_client:
            await http_api_client.async_logout()

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    log_message(f"🚀 Iniciando Meross Timer API en puerto {port}")
    log_message(f"📧 Email configurado: {os.getenv('MEROSS_EMAIL', 'NO CONFIGURADO')}")
    log_message(f"🔑 API Key configurada: {'SÍ' if os.getenv('MEROSS_API_KEY') else 'NO (opcional)'}")
    
    # Mostrar rutas disponibles
    print("\n=== RUTAS DISPONIBLES ===")
    print("GET  /                     - Health check")
    print("GET  /status               - Estado del servicio")
    print("GET  /jobs                 - Ver trabajos activos")
    print("GET  /test-connection      - Probar conexión (sin API key)")
    print("POST /test-connection      - Probar conexión (con API key)")
    print("GET  /kodiplex/off/<min>   - Apagar KodiPlex en X minutos")
    print("GET  /kodiplex/on/<min>    - Encender KodiPlex en X minutos")
    print("POST /timer                - Temporizador personalizado")
    print("POST /cancel-job           - Cancelar trabajo")
    print("========================\n")
    
    app.run(host='0.0.0.0', port=port)
