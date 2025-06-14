import os
import threading
import time
import json
import hashlib
import random
import string
import requests
from datetime import datetime, timedelta
import pytz
from flask import Flask, request, jsonify

app = Flask(__name__)

# Configurar timezone de España
SPAIN_TZ = pytz.timezone('Europe/Madrid')

# Diccionario para trackear tareas activas
active_tasks = {}

# Cache mejorado con persistencia de tokens
_mobile_cache = {
    'token': None,
    'user_id': None,
    'key': None,
    'devices': None,
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
        'Content-Type': 'application/json; charset=UTF-8',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache'
    }

def generate_nonce():
    """Generar nonce aleatorio"""
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=16))

def encode_password(password, nonce):
    """Codificar password con MD5 como hace la app real"""
    return hashlib.md5((password + nonce).encode()).hexdigest()

class MerossRealClient:
    """Cliente que usa la API real de Meross"""
    
    def __init__(self, email, password):
        self.email = email
        self.password = password
        self.base_url = 'https://iotx-eu.meross.com'
        self.session = requests.Session()
        self.token = None
        self.key = None
        self.user_id = None
        self.headers = generate_mobile_headers()
        
        # Configurar sesión
        self.session.headers.update(self.headers)
        self.session.timeout = 30
    
    def login(self):
        """Login con la API real de Meross"""
        nonce = generate_nonce()
        encoded_password = encode_password(self.password, nonce)
        
        login_data = {
            'email': self.email,
            'password': encoded_password,
            'nonce': nonce
        }
        
        try:
            log_message(f"🔐 Intentando login con API real de Meross...")
            
            response = self.session.post(
                f'{self.base_url}/v1/Auth/signIn',
                json=login_data,
                timeout=30
            )
            
            log_message(f"📡 Login response status: {response.status_code}")
            
            if response.status_code == 200:
                data = response.json()
                log_message(f"📋 Login response data keys: {list(data.keys())}")
                
                if data.get('apiStatus') == 0:
                    auth_data = data.get('data', {})
                    self.token = auth_data.get('token')
                    self.key = auth_data.get('key')
                    self.user_id = auth_data.get('userid')
                    
                    log_message(f"✅ Login exitoso - Token: {self.token[:20] if self.token else 'None'}...")
                    
                    # Actualizar headers con token
                    if self.token:
                        self.session.headers['Authorization'] = f'Basic {self.token}'
                    
                    return True
                else:
                    error_msg = data.get('info', 'Login failed')
                    log_message(f"❌ Login API error: {error_msg}")
                    raise Exception(f"Login API error: {error_msg}")
            else:
                error_text = response.text
                log_message(f"❌ HTTP {response.status_code}: {error_text}")
                raise Exception(f"HTTP {response.status_code}: {error_text}")
                
        except Exception as e:
            log_message(f"💥 Login failed: {str(e)}")
            raise Exception(f"Login failed: {str(e)}")
    
    def get_devices(self):
        """Obtener dispositivos con la API real"""
        if not self.token:
            raise Exception("No authenticated")
        
        try:
            log_message(f"📱 Obteniendo lista de dispositivos...")
            
            response = self.session.post(
                f'{self.base_url}/v1/Device/devList',
                json={},
                timeout=30
            )
            
            log_message(f"📡 Devices response status: {response.status_code}")
            
            if response.status_code == 200:
                data = response.json()
                log_message(f"📋 Devices response data keys: {list(data.keys())}")
                
                if data.get('apiStatus') == 0:
                    devices = data.get('data', [])
                    log_message(f"📱 {len(devices)} dispositivos encontrados")
                    return devices
                else:
                    error_msg = data.get('info', 'Device list failed')
                    log_message(f"❌ Device list error: {error_msg}")
                    raise Exception(f"Device list error: {error_msg}")
            else:
                error_text = response.text
                log_message(f"❌ HTTP {response.status_code}: {error_text}")
                raise Exception(f"HTTP {response.status_code}: {error_text}")
                
        except Exception as e:
            log_message(f"💥 Get devices failed: {str(e)}")
            raise Exception(f"Get devices failed: {str(e)}")
    
    def control_device(self, device_uuid, command):
        """Controlar dispositivo con la API real"""
        if not self.token:
            raise Exception("No authenticated")
        
        control_data = {
            'uuid': device_uuid,
            'command': command
        }
        
        try:
            log_message(f"🎮 Enviando comando a dispositivo {device_uuid[:8]}...")
            log_message(f"📋 Comando: {json.dumps(command, indent=2)}")
            
            response = self.session.post(
                f'{self.base_url}/v1/Device/controlByUuid',
                json=control_data,
                timeout=30
            )
            
            log_message(f"📡 Control response status: {response.status_code}")
            
            if response.status_code == 200:
                data = response.json()
                log_message(f"📋 Control response: {data}")
                
                if data.get('apiStatus') == 0:
                    log_message(f"✅ Control exitoso")
                    return True
                else:
                    error_msg = data.get('info', 'Control failed')
                    log_message(f"❌ Control error: {error_msg}")
                    raise Exception(f"Control error: {error_msg}")
            else:
                error_text = response.text
                log_message(f"❌ HTTP {response.status_code}: {error_text}")
                raise Exception(f"HTTP {response.status_code}: {error_text}")
                
        except Exception as e:
            log_message(f"💥 Device control failed: {str(e)}")
            raise Exception(f"Device control failed: {str(e)}")

def get_meross_client_and_devices(email, password, job_id):
    """Obtener cliente real y dispositivos con cache"""
    try:
        with _mobile_cache['lock']:
            now = datetime.now()
            
            # Verificar cache válido (3 minutos)
            if (_mobile_cache['token'] is not None and 
                _mobile_cache['last_update'] is not None and 
                (now - _mobile_cache['last_update']).total_seconds() < 180):
                
                log_message(f"📱 [{job_id}] Usando sesión cacheada")
                
                # Crear cliente temporal con datos cacheados
                client = MerossRealClient(email, password)
                client.token = _mobile_cache['token']
                client.key = _mobile_cache['key']
                client.user_id = _mobile_cache['user_id']
                if client.token:
                    client.session.headers['Authorization'] = f'Basic {client.token}'
                
                return client, _mobile_cache['devices']
            
            log_message(f"📱 [{job_id}] Creando nueva sesión con API real...")
            
            # Crear nuevo cliente
            client = MerossRealClient(email, password)
            
            # Login
            client.login()
            log_message(f"✅ [{job_id}] Login exitoso")
            
            # Pequeña pausa para estabilizar
            time.sleep(2)
            
            # Obtener dispositivos
            devices_data = client.get_devices()
            log_message(f"📱 [{job_id}] {len(devices_data)} dispositivos encontrados")
            
            # Actualizar cache
            _mobile_cache['token'] = client.token
            _mobile_cache['key'] = client.key
            _mobile_cache['user_id'] = client.user_id
            _mobile_cache['devices'] = devices_data
            _mobile_cache['last_update'] = now
            
            return client, devices_data
            
    except Exception as e:
        log_message(f"💥 [{job_id}] Error en cliente real: {str(e)}")
        raise

def control_device_real(email, password, device_name, action, job_id, max_retries=2):
    """Control de dispositivo con API real de Meross"""
    
    for attempt in range(max_retries):
        try:
            log_message(f"🎮 [{job_id}] Intento {attempt + 1}/{max_retries} - Control real {device_name} -> {action}")
            
            # Obtener cliente y dispositivos
            client, devices_data = get_meross_client_and_devices(email, password, job_id)
            
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
            
            log_message(f"🎯 [{job_id}] Dispositivo encontrado: {target_device.get('devName')} (UUID: {device_uuid[:8]}...)")
            log_message(f"📋 [{job_id}] Tipo: {device_type}")
            
            # Preparar comando según el tipo de dispositivo
            message_id = f"msg_{int(time.time())}_{random.randint(1000, 9999)}"
            
            if 'mss110' in device_type.lower() or 'plug' in device_type.lower():
                command = {
                    "header": {
                        "messageId": message_id,
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
                command = {
                    "header": {
                        "messageId": message_id,
                        "method": "SET",
                        "namespace": "Appliance.Control.Toggle"
                    },
                    "payload": {
                        "toggle": {
                            "onoff": 1 if action == "on" else 0
                        }
                    }
                }
            
            # Ejecutar comando
            client.control_device(device_uuid, command)
            
            log_message(f"✅ [{job_id}] Control real exitoso: {target_device.get('devName')} -> {action}")
            
            return {
                "status": "success", 
                "message": f"Acción '{action}' ejecutada en {target_device.get('devName')} via API real"
            }
            
        except Exception as e:
            error_msg = str(e)
            log_message(f"💥 [{job_id}] Error en intento real {attempt + 1}: {error_msg}")
            
            # Limpiar cache en caso de error de autenticación
            if any(keyword in error_msg.lower() for keyword in ['auth', 'token', 'login', 'unauthorized', '401']):
                log_message(f"🔄 [{job_id}] Error de autenticación, limpiando cache...")
                with _mobile_cache['lock']:
                    _mobile_cache.update({
                        'token': None, 'devices': None, 'key': None,
                        'user_id': None, 'last_update': None, 'session_id': None
                    })
            
            if attempt < max_retries - 1:
                wait_time = (attempt + 1) * 30
                log_message(f"⏳ [{job_id}] Esperando {wait_time} segundos antes del siguiente intento...")
                time.sleep(wait_time)
            else:
                return {
                    "status": "error", 
                    "message": f"Error después de {max_retries} intentos: {error_msg}"
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
        log_message(f"🚀 [{job_id}] ¡Tiempo cumplido! Ejecutando acción real...")
        
        # Ejecutar la acción con API real
        result = control_device_real(email, password, device_name, action, job_id)
        log_message(f"🎯 [{job_id}] Resultado real: {result}")
        
        # Actualizar estado final
        active_tasks[job_id]["status"] = "completed"
        active_tasks[job_id]["result"] = result
        
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
            "api_version": "real_api_v3.0"
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
                    "api_type": "real_api"
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
                    "api_type": "real_api"
                })
        
        return jsonify({
            "status": "success",
            "active_jobs": len(active_tasks),
            "jobs": jobs_info,
            "spain_time": now_spain.strftime('%H:%M:%S %d/%m/%Y %Z'),
            "timestamp": now_spain.isoformat(),
            "api_version": "real_api_v3.0"
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
        
        log_message(f"📱 Programando (API real): {device_name} -> {action} en {minutes} minutos")
        
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
            "message": f"Programado {action} en {device_name} después de {minutes} minutos (API real)",
            "job_id": job_id,
            "execution_time": execution_time.isoformat(),
            "execution_time_spain": execution_time.strftime('%H:%M:%S %d/%m/%Y'),
            "platform": "render",
            "api_type": "real_api"
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
    """Limpiar cache manualmente"""
    try:
        data = request.get_json()
        api_key = data.get('api_key')
        api_key_env = os.getenv('MEROSS_API_KEY')
        
        if not api_key or api_key != api_key_env:
            return jsonify({"status": "error", "message": "Clave API inválida"}), 401
        
        with _mobile_cache['lock']:
            _mobile_cache.update({
                'token': None, 'devices': None, 'key': None,
                'user_id': None, 'last_update': None, 'session_id': None
            })
            
        log_message("✅ Cache limpiado manualmente")
        return jsonify({
            "status": "success",
            "message": "Cache limpiado exitosamente"
        })
        
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/test-connection', methods=['POST'])
def test_connection():
    """Probar conexión sin ejecutar acciones"""
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
        test_job_id = f"test_connection_{datetime.now(SPAIN_TZ).strftime('%H%M%S')}"
        
        try:
            client, devices_data = get_meross_client_and_devices(email, password, test_job_id)
            device_list = []
            
            for device_info in devices_data:
                device_list.append({
                    "name": device_info.get('devName', 'Unknown'),
                    "type": device_info.get('deviceType', 'Unknown'),
                    "uuid": device_info.get('uuid', '')[:8] + "...",
                    "online": device_info.get('onlineStatus', 0) == 1
                })
            
            return jsonify({
                "status": "success",
                "message": "Conexión API real exitosa",
                "devices_found": len(devices_data),
                "devices": device_list,
                "api_type": "real_api"
            })
        except Exception as e:
            return jsonify({
                "status": "error",
                "message": f"Error de conexión API real: {str(e)}",
                "api_type": "real_api"
            })
            
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/', methods=['GET'])
def health_check():
    """Health check endpoint para Render"""
    return jsonify({
        "status": "healthy",
        "service": "Meross Timer API Real v3.0",
        "platform": "render",
        "timestamp": datetime.now(SPAIN_TZ).isoformat(),
        "api_type": "real_api",
        "features": [
            "Real Meross API integration",
            "Proper authentication with MD5 encoding", 
            "Correct API endpoints",
            "Timer scheduling",
            "Job management", 
            "Connection caching",
            "Error recovery",
            "Manual cache clearing",
            "Connection testing",
            "Python 3.13 compatible"
        ]
    })

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    log_message(f"📱 Iniciando Meross Timer API Real v3.0 en puerto {port}")
    app.run(host='0.0.0.0', port=port)

from flask import Flask, request, jsonify
import os, time, uuid, hashlib, requests

app = Flask(__name__)

# ————— MerossClient ultraligero ——————
BASE_URL = "https://iotx-eu.meross.com/v1"

def md5_str(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()

class MerossClient:
    def __init__(self, email, password):
        self.email = email
        self.password = password
        self.token = None
        self.user_id = None
        self.s = requests.Session()

    def login(self):
        ts = int(time.time())
        nonce = uuid.uuid4().hex[:8]
        pwd_md5 = md5_str(self.password)
        sign = md5_str(f"{self.email}{pwd_md5}{ts}{nonce}")
        body = {
            "email": self.email,
            "password": pwd_md5,
            "timestamp": ts,
            "sign": sign,
            "nonce": nonce
        }
        print("→ LOGIN REQ:", body)
        resp = self.s.post(f"{BASE_URL}/Auth/signIn", json=body)
        print("← LOGIN RESP:", resp.status_code, resp.text)
        data = resp.json().get("data", {})
        self.token = data.get("token")
        self.user_id = data.get("userId")
        if not self.token or not self.user_id:
            raise RuntimeError("Login failed")

    def list_devices(self):
        ts = int(time.time())
        hdr = {"Authorization": self.token}
        body = {"timestamp": ts, "userId": self.user_id}
        print("→ DEVLIST REQ:", body)
        resp = self.s.post(f"{BASE_URL}/Device/devList", json=body, headers=hdr)
        print("← DEVLIST RESP:", resp.status_code, resp.text)
        return resp.json()

    def control(self, device_id, on):
        ts = int(time.time())
        hdr = {"Authorization": self.token}
        body = {
            "header": {
                "messageId": str(uuid.uuid4()),
                "namespace": "Appliance.Control.ToggleX",
                "method": "SET",
                "payloadVersion": 1,
                "timestamp": ts
            },
            "payload": {"deviceId": device_id, "channel": 0, "onoff": 1 if on else 0}
        }
        print("→ CONTROL REQ:", body)
        resp = self.s.post(f"{BASE_URL}/Appliance.Control.ToggleX", json=body, headers=hdr)
        print("← CONTROL RESP:", resp.status_code, resp.text)
        return resp.json()

# ————— Endpoint de debug ——————
# … tus imports, MerossClient, otros endpoints …

@app.route("/debug-meross", methods=["GET", "POST"])
def debug_meross():
    """
    Soporta:
      - GET  /debug-meross?action=on|off&device_id=<ID>
      - POST /debug-meross  con JSON { action, device_id }
    """
    # 1) lecturas de credenciales
    email = os.getenv("MEROSS_EMAIL")
    password = os.getenv("MEROSS_PASSWORD")
    if not email or not password:
        return jsonify(error="Faltan MEROSS_EMAIL o MEROSS_PASSWORD"), 400

    # 2) leer params según método
    if request.method == "POST":
        payload = request.get_json() or {}
    else:  # GET
        payload = {
            "action": request.args.get("action"),
            "device_id": request.args.get("device_id")
        }

    action = payload.get("action")
    dev_id = payload.get("device_id")
    if action not in ("on", "off") or not dev_id:
        return jsonify(error="action debe ser 'on'/'off' y device_id válido"), 400

    # 3) lógica Meross
    try:
        cli = MerossClient(email, password)
        cli.login()
        cli.list_devices()
        result = cli.control(device_id=dev_id, on=(action=="on"))
        return jsonify(result=result)
    except Exception as e:
        return jsonify(error=str(e)), 500

# al final de temporizador.py
if __name__ == "__main__":
    # debug: imprime todas las rutas registradas
    print("=== RUTAS DISPONIBLES EN FLASK ===")
    for rule in app.url_map.iter_rules():
        print(rule)
    print("=================================")
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 5000)))
