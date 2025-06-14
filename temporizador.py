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

async def control_device(email, password, device_name, action, job_id, max_retries=3):
    """Control de dispositivo"""
    for attempt in range(max_retries):
        try:
            log_message(f"🔧 [{job_id}] Intento {attempt + 1}/{max_retries} - Controlando {device_name} -> {action}")
            
            http_api_client = await MerossHttpClient.async_from_user_password(
                email=email,
                password=password,
                api_base_url='https://iot.meross.com'
            )
            
            manager = MerossManager(http_client=http_api_client)
            await manager.async_init()
            await manager.async_device_discovery()
            devices = manager.find_devices()
            
            target_device = None
            for device in devices:
                if device_name.lower() in device.name.lower():
                    target_device = device
                    break
            
            if not target_device:
                log_message(f"❌ [{job_id}] Dispositivo no encontrado: {device_name}")
                return {"status": "error", "message": f"Dispositivo '{device_name}' no encontrado"}
            
            if action == "on":
                await target_device.async_turn_on(channel=0)
            elif action == "off":
                await target_device.async_turn_off(channel=0)
            
            log_message(f"✅ [{job_id}] Acción completada: {device_name} -> {action}")
            
            manager.close()
            await http_api_client.async_logout()
            
            return {"status": "success", "message": f"Acción '{action}' ejecutada en {device_name}"}
            
        except Exception as e:
            log_message(f"💥 [{job_id}] Error en intento {attempt + 1}: {str(e)}")
            if attempt < max_retries - 1:
                wait_time = (attempt + 1) * 15
                log_message(f"⏳ [{job_id}] Esperando {wait_time} segundos antes del siguiente intento...")
                await asyncio.sleep(wait_time)
            else:
                return {"status": "error", "message": f"Error después de {max_retries} intentos: {str(e)}"}

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
        
        # Ejecutar la acción
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            result = loop.run_until_complete(
                control_device(email, password, device_name, action, job_id)
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
                # Parsear tiempo de ejecución
                execution_time = datetime.fromisoformat(task['execution_time'])
                # Formatear tiempo para España
                execution_time_spain = execution_time.strftime('%H:%M:%S %d/%m/%Y')
                
                # Calcular tiempo restante
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
                
                # Agregar información adicional según el estado
                if task.get('status') == "completed" and 'result' in task:
                    job_info['result'] = task['result']
                elif task.get('status') == "error" and 'error' in task:
                    job_info['error'] = task['error']
                
                jobs_info.append(job_info)
                
            except Exception as e:
                log_message(f"❌ Error procesando job {job_id}: {str(e)}")
                jobs_info.append({
                    "id": job_id,
                    "name": f"Control {task.get('device_name', 'Unknown')} -> {task.get('action', 'Unknown')}",
                    "execution_time": task.get('execution_time', ''),
                    "execution_time_spain": "Error parsing time",
                    "status": task.get('status', 'error'),
                    "remaining_minutes": 0,
                    "remaining_seconds": 0,
                    "error": f"Error parsing job data: {str(e)}"
                })
        
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
        
        if not all([email, password, device_name, api_key]):
            return jsonify({"status": "error", "message": "Faltan parámetros requeridos"}), 400
        
        if api_key != api_key_env:
            return jsonify({"status": "error", "message": "Clave API inválida"}), 401
        
        if minutes < 1:
            return jsonify({"status": "error", "message": "El tiempo mínimo es 1 minuto"}), 400
        
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

@app.route('/cancel-job', methods=['POST'])
def cancel_job():
    try:
        data = request.get_json()
        job_id = data.get('job_id')
        api_key = data.get('api_key')
        api_key_env = os.getenv('MEROSS_API_KEY')
        
        if not job_id or not api_key:
            return jsonify({"status": "error", "message": "job_id y api_key son requeridos"}), 400
        
        if api_key != api_key_env:
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

@app.route('/', methods=['GET'])
def health_check():
    """Health check endpoint para Render"""
    return jsonify({
        "status": "healthy",
        "service": "Meross Timer API",
        "platform": "render",
        "timestamp": datetime.now(SPAIN_TZ).isoformat()
    })

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port)
