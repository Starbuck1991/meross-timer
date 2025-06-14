import asyncio
import os
import threading
import time
import json
import hashlib
import random
import string
from datetime import datetime, timedelta
import pytz
from flask import Flask, request, jsonify
from meross_iot.http_api import MerossHttpClient
from meross_iot.manager import MerossManager
import aiohttp
import ssl

app = Flask(__name__)

# Configurar timezone de España
SPAIN_TZ = pytz.timezone('Europe/Madrid')

# Diccionario para trackear tareas activas
active_tasks = {}

# Cache mejorado con persistencia de tokens
_enhanced_cache = {
    'manager': None,
    'devices': None,
    'token': None,
    'user_id': None,
    'key': None,
    'last_update': None,
    'session_id': None,
    'lock': threading.Lock()
}

def log_message(message):
    timestamp = datetime.now(SPAIN_TZ).strftime("%Y-%m-%d %H:%M:%S %Z")
    print(f"[{timestamp}] {message}", flush=True)

def generate_mobile_headers():
    """Generar headers que simulan un dispositivo móvil Android"""
    session_id = ''.join(random.choices(string.ascii_lowercase + string.digits, k=32))
    
    return {
        'User-Agent': 'okhttp/3.14.9',
        'Accept': 'application/json',
        'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        'Accept-Encoding': 'gzip, deflate',
        'Connection': 'keep-alive',
        'X-Requested-With': 'com.meross.meross',
        'Content-Type': 'application/json; charset=UTF-8',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
        'X-Session-ID': session_id,
        'X-Device-Type': 'android',
        'X-App-Version': '4.4.6',
        'X-OS-Version': '11',
        'X-Device-Model': 'SM-G973F'
    }

class EnhancedMerossClient:
    """Cliente Meross mejorado con simulación móvil"""
    
    def __init__(self, email, password):
        self.email = email
        self.password = password
        self.base_url = 'https://iotx-eu.meross.com'
        self.session = None
        self.token = None
        self.key = None
        self.user_id = None
        self.headers = generate_mobile_headers()
    
    async def create_session(self):
        """Crear sesión HTTP con configuración móvil"""
        connector = aiohttp.TCPConnector(
            ssl=ssl.create_default_context(),
            limit=10,
            limit_per_host=5,
            keepalive_timeout=30,
            enable_cleanup_closed=True
        )
        
        timeout = aiohttp.ClientTimeout(total=30, connect=10)
        
        self.session = aiohttp.ClientSession(
            connector=connector,
            timeout=timeout,
            headers=self.headers
        )
    
    async def mobile_login(self):
        """Login simulando app móvil"""
        if not self.session:
            await self.create_session()
        
        # Generar timestamp y nonce como lo hace la app móvil
        timestamp = int(time.time())
        nonce = ''.join(random.choices(string.ascii_lowercase + string.digits, k=16))
        
        # Datos de login con formato móvil
        login_data = {
            'email': self.email,
            'password': self.password,
            'encryption': 1,
            'mobileInfo': {
                'uuid': self.headers['X-Session-ID'],
                'vendor': 'Samsung',
                'model': 'SM-G973F',
                'osVersion': '11',
                'appVersion': '4.4.6',
                'carrier': 'WiFi',
                'language': 'es_ES',
                'timezone': 'Europe/Madrid'
            },
            'timestamp': timestamp,
            'nonce': nonce
        }
        
        try:
            # Intentar login
            async with self.session.post(
                f'{self.base_url}/v1/Auth/Login',
                json=login_data,
                headers={**self.headers, 'X-Timestamp': str(timestamp)}
            ) as response:
                
                if response.status == 200:
                    data = await response.json()
                    
                    if data.get('apiStatus') == 0:  # Éxito
                        auth_data = data.get('data', {})
                        self.token = auth_data.get('token')
                        self.key = auth_data.get('key')
                        self.user_id = auth_data.get('userid')
                        
                        # Actualizar headers con token
                        self.headers['Authorization'] = f'Basic {self.token}'
                        
                        return True
                    else:
                        error_msg = data.get('info', 'Login failed')
                        raise Exception(f"Login API error: {error_msg}")
                else:
                    raise Exception(f"HTTP {response.status}: {await response.text()}")
                    
        except Exception as e:
            raise Exception(f"Mobile login failed: {str(e)}")
    
    async def get_devices_mobile(self):
        """Obtener dispositivos con API móvil"""
        if not self.token:
            raise Exception("No authenticated")
        
        timestamp = int(time.time())
        
        try:
            async with self.session.post(
                f'{self.base_url}/v1/Device/devList',
                json={'timestamp': timestamp},
                headers={**self.headers, 'X-Timestamp': str(timestamp)}
            ) as response:
                
                if response.status == 200:
                    data = await response.json()
                    if data.get('apiStatus') == 0:
                        return data.get('data', [])
                    else:
                        raise Exception(f"Device list error: {data.get('info')}")
                else:
                    raise Exception(f"HTTP {response.status}")
                    
        except Exception as e:
            raise Exception(f"Get devices failed: {str(e)}")
    
    async def control_device_mobile(self, device_uuid, command):
        """Controlar dispositivo con API móvil"""
        if not self.token:
            raise Exception("No authenticated")
        
        timestamp = int(time.time())
        
        control_data = {
            'uuid': device_uuid,
            'command': command,
            'timestamp': timestamp
        }
        
        try:
            async with self.session.post(
                f'{self.base_url}/v1/Device/controlByUuid',
                json=control_data,
                headers={**self.headers, 'X-Timestamp': str(timestamp)}
            ) as response:
                
                if response.status == 200:
                    data = await response.json()
                    if data.get('apiStatus') == 0:
                        return True
                    else:
                        raise Exception(f"Control error: {data.get('info')}")
                else:
                    raise Exception(f"HTTP {response.status}")
                    
        except Exception as e:
            raise Exception(f"Device control failed: {str(e)}")
    
    async def close(self):
        """Cerrar sesión"""
        if self.session:
            await self.session.close()

async def get_enhanced_manager_and_devices(email, password, job_id):
    """Manager mejorado con cliente móvil"""
    try:
        with _enhanced_cache['lock']:
            now = datetime.now()
            
            # Verificar cache válido (3 minutos para móvil)
            if (_enhanced_cache['token'] is not None and 
                _enhanced_cache['last_update'] is not None and 
                (now - _enhanced_cache['last_update']).total_seconds() < 180):
                
                log_message(f"📱 [{job_id}] Usando sesión móvil cacheada")
                return _enhanced_cache['manager'], _enhanced_cache['devices']
            
            # Limpiar cache anterior
            if _enhanced_cache['manager']:
                try:
                    await _enhanced_cache['manager'].close()
                except:
                    pass
            
            log_message(f"📱 [{job_id}] Creando nueva sesión móvil...")
            
            # Crear cliente móvil
            mobile_client = EnhancedMerossClient(email, password)
            
            # Login móvil
            await mobile_client.mobile_login()
            log_message(f"✅ [{job_id}] Login móvil exitoso")
            
            # Pequeña pausa para estabilizar
            await asyncio.sleep(1)
            
            # Obtener dispositivos
            devices_data = await mobile_client.get_devices_mobile()
            log_message(f"📱 [{job_id}] {len(devices_data)} dispositivos encontrados")
            
            # Actualizar cache
            _enhanced_cache['manager'] = mobile_client
            _enhanced_cache['token'] = mobile_client.token
            _enhanced_cache['devices'] = devices_data
            _enhanced_cache['last_update'] = now
            
            return mobile_client, devices_data
            
    except Exception as e:
        log_message(f"💥 [{job_id}] Error en enhanced manager: {str(e)}")
        raise

async def control_device_enhanced(email, password, device_name, action, job_id, max_retries=2):
    """Control de dispositivo con API móvil"""
    
    for attempt in range(max_retries):
        try:
            log_message(f"📱 [{job_id}] Intento {attempt + 1}/{max_retries} - Control móvil {device_name} -> {action}")
            
            # Obtener cliente móvil y dispositivos
            mobile_client, devices_data = await get_enhanced_manager_and_devices(email, password, job_id)
            
            # Buscar dispositivo
            target_device = None
            for device_info in devices_data:
                device_dev_name = device_info.get('devName', '')
                if device_name.lower() in device_dev_name.lower():
                    target_device = device_info
                    break
            
            if not target_device:
                available_devices = [d.get('devName', 'Unknown') for d in devices_data]
                return {
                    "status": "error", 
                    "message": f"Dispositivo '{device_name}' no encontrado. Disponibles: {available_devices}"
                }
            
            device_uuid = target_device.get('uuid')
            device_type = target_device.get('deviceType', '')
            
            log_message(f"📱 [{job_id}] Dispositivo encontrado: {target_device.get('devName')} (UUID: {device_uuid[:8]}...)")
            
            # Preparar comando según el tipo de dispositivo
            if 'mss110' in device_type.lower() or 'plug' in device_type.lower():
                # Enchufe inteligente
                command = {
                    "header": {
                        "messageId": f"msg_{int(time.time())}",
                        "method": "SET",
                        "namespace": "Appliance.Control.ToggleX"
                    },
                    "payload": {
                        "togglex": [{
                            "channel": 0,
                            "onoff": 1 if action == "on" else 0
                        }]
                    }
                }
            else:
                # Comando genérico
                command = {
                    "header": {
                        "messageId": f"msg_{int(time.time())}",
                        "method": "SET",
                        "namespace": "Appliance.Control.Toggle"
                    },
                    "payload": {
                        "toggle": {
                            "onoff": 1 if action == "on" else 0
                        }
                    }
                }
            
            # Ejecutar comando con timeout
            try:
                await asyncio.wait_for(
                    mobile_client.control_device_mobile(device_uuid, command), 
                    timeout=15
                )
                
                log_message(f"✅ [{job_id}] Control móvil exitoso: {target_device.get('devName')} -> {action}")
                
                return {
                    "status": "success", 
                    "message": f"Acción '{action}' ejecutada en {target_device.get('devName')} via API móvil"
                }
                
            except asyncio.TimeoutError:
                log_message(f"⏰ [{job_id}] Timeout en control móvil, pero comando enviado")
                return {
                    "status": "success", 
                    "message": f"Comando '{action}' enviado a {target_device.get('devName')} (timeout en confirmación)"
                }
            
        except Exception as e:
            error_msg = str(e)
            log_message(f"💥 [{job_id}] Error en intento móvil {attempt + 1}: {error_msg}")
            
            # Limpiar cache en caso de error de autenticación
            if any(keyword in error_msg.lower() for keyword in ['auth', 'token', 'login', 'mfa']):
                log_message(f"🔄 [{job_id}] Error de autenticación, limpiando cache móvil...")
                with _enhanced_cache['lock']:
                    if _enhanced_cache['manager']:
                        try:
                            await _enhanced_cache['manager'].close()
                        except:
                            pass
                    _enhanced_cache.update({
                        'manager': None, 'devices': None, 'token': None,
                        'user_id': None, 'key': None, 'last_update': None
                    })
            
            if attempt < max_retries - 1:
                wait_time = (attempt + 1) * 25  # Más tiempo entre reintentos
                log_message(f"⏳ [{job_id}] Esperando {wait_time} segundos antes del siguiente intento móvil...")
                await asyncio.sleep(wait_time)
            else:
                return {
                    "status": "error", 
                    "message": f"Error después de {max_retries} intentos móviles: {error_msg}"
                }

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
        log_message(f"🚀 [{job_id}] ¡Tiempo cumplido! Ejecutando acción móvil...")
        
        # Ejecutar la acción con API móvil
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            result = loop.run_until_complete(
                control_device_enhanced(email, password, device_name, action, job_id)
            )
            log_message(f"🎯 [{job_id}] Resultado móvil: {result}")
            
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
            "platform": "render",
            "api_version": "mobile_v2.0"
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
                    "remaining_seconds": remaining_seconds,
                    "api_type": "mobile"
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
                    "error": f"Error parsing job data: {str(e)}",
                    "api_type": "mobile"
                })
        
        return jsonify({
            "status": "success",
            "active_jobs": len(active_tasks),
            "jobs": jobs_info,
            "spain_time": now_spain.strftime('%H:%M:%S %d/%m/%Y %Z'),
            "timestamp": now_spain.isoformat(),
            "api_version": "mobile_v2.0"
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
        
        log_message(f"📱 Programando (API móvil): {device_name} -> {action} en {minutes} minutos")
        
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
            "message": f"Programado {action} en {device_name} después de {minutes} minutos (API móvil)",
            "job_id": job_id,
            "execution_time": execution_time.isoformat(),
            "execution_time_spain": execution_time.strftime('%H:%M:%S %d/%m/%Y'),
            "platform": "render",
            "api_type": "mobile"
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

@app.route('/clear-cache', methods=['POST'])
def clear_cache():
    """Limpiar cache móvil manualmente"""
    try:
        data = request.get_json()
        api_key = data.get('api_key')
        api_key_env = os.getenv('MEROSS_API_KEY')
        
        if not api_key or api_key != api_key_env:
            return jsonify({"status": "error", "message": "Clave API inválida"}), 401
        
        with _enhanced_cache['lock']:
            if _enhanced_cache['manager']:
                try:
                    asyncio.run(_enhanced_cache['manager'].close())
                    log_message("🧹 Cliente móvil cerrado")
                except:
                    pass
            
            _enhanced_cache.update({
                'manager': None, 'devices': None, 'token': None,
                'user_id': None, 'key': None, 'last_update': None, 'session_id': None
            })
            
        log_message("✅ Cache móvil limpiado manualmente")
        return jsonify({
            "status": "success",
            "message": "Cache móvil limpiado exitosamente"
        })
        
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/test-mobile', methods=['POST'])
def test_mobile_connection():
    """Probar conexión móvil sin ejecutar acciones"""
    try:
        data = request.get_json()
        api_key = data.get('api_key')
        api_key_env = os.getenv('MEROSS_API_KEY')
        
        if not api_key or api_key != api_key_env:
            return jsonify({"status": "error", "message": "Clave API inválida"}), 401
        
        email = os.getenv('MEROSS_EMAIL')
        password = os.getenv('MEROSS_PASSWORD')
        
        if not email or not password:
            return jsonify({
                "status": "error", 
                "message": "Variables de entorno MEROSS_EMAIL o MEROSS_PASSWORD no configuradas"
            }), 500
        
        # Crear job_id temporal para logs
        test_job_id = f"test_mobile_{datetime.now(SPAIN_TZ).strftime('%H%M%S')}"
        
        async def test_mobile_async():
            try:
                mobile_client, devices_data = await get_enhanced_manager_and_devices(email, password, test_job_id)
                device_list = []
                
                for device_info in devices_data:
                    device_list.append({
                        "name": device_info.get('devName', 'Unknown'),
                        "type": device_info.get('deviceType', 'Unknown'),
                        "uuid": device_info.get('uuid', '')[:8] + "...",
                        "online": device_info.get('onlineStatus', 0) == 1
                    })
                
                return {
                    "status": "success",
                    "message": "Conexión móvil exitosa",
                    "devices_found": len(devices_data),
                    "devices": device_list,
                    "api_type": "mobile"
                }
            except Exception as e:
                return {
                    "status": "error",
                    "message": f"Error de conexión móvil: {str(e)}",
                    "api_type": "mobile"
                }
        
        # Ejecutar test
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            result = loop.run_until_complete(test_mobile_async())
            return jsonify(result)
        finally:
            loop.close()
            
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/', methods=['GET'])
def health_check():
    """Health check endpoint para Render"""
    return jsonify({
        "status": "healthy",
        "service": "Meross Timer API Mobile v2.0",
        "platform": "render",
        "timestamp": datetime.now(SPAIN_TZ).isoformat(),
        "api_type": "mobile_simulation",
        "features": [
            "Mobile API simulation",
            "Android headers spoofing", 
            "Enhanced session management",
            "Timer scheduling",
            "Job management", 
            "Connection caching",
            "Error recovery",
            "Manual cache clearing",
            "Mobile connection testing"
        ]
    })

# Cleanup al cerrar la aplicación
import atexit

def cleanup_on_exit():
    """Limpiar recursos al cerrar"""
    try:
        with _enhanced_cache['lock']:
            if _enhanced_cache['manager']:
                asyncio.run(_enhanced_cache['manager'].close())
                log_message("🧹 Cliente móvil cerrado al salir")
    except:
        pass

atexit.register(cleanup_on_exit)

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    log_message(f"📱 Iniciando Meross Timer API Mobile v2.0 en puerto {port}")
    app.run(host='0.0.0.0', port=port)
