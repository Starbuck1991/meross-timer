            
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
            "api_version": "mobile_simple_v2.1"
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
                    "api_type": "mobile_simple"
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
                    "api_type": "mobile_simple"
                })
        
        return jsonify({
            "status": "success",
            "active_jobs": len(active_tasks),
            "jobs": jobs_info,
            "spain_time": now_spain.strftime('%H:%M:%S %d/%m/%Y %Z'),
            "timestamp": now_spain.isoformat(),
            "api_version": "mobile_simple_v2.1"
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
        
        log_message(f"📱 Programando (API móvil simple): {device_name} -> {action} en {minutes} minutos")
        
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
            "message": f"Programado {action} en {device_name} después de {minutes} minutos (API móvil simple)",
            "job_id": job_id,
            "execution_time": execution_time.isoformat(),
            "execution_time_spain": execution_time.strftime('%H:%M:%S %d/%m/%Y'),
            "platform": "render",
            "api_type": "mobile_simple"
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
        
        with _mobile_cache['lock']:
            _mobile_cache.update({
                'token': None, 'devices': None, 'key': None,
                'user_id': None, 'last_update': None, 'session_id': None
            })
            
        log_message("✅ Cache móvil simple limpiado manualmente")
        return jsonify({
            "status": "success",
            "message": "Cache móvil simple limpiado exitosamente"
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
        
        try:
            client, devices_data = get_mobile_client_and_devices(email, password, test_job_id)
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
                "message": "Conexión móvil simple exitosa",
                "devices_found": len(devices_data),
                "devices": device_list,
                "api_type": "mobile_simple"
            })
        except Exception as e:
            return jsonify({
                "status": "error",
                "message": f"Error de conexión móvil simple: {str(e)}",
                "api_type": "mobile_simple"
            })
            
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/', methods=['GET'])
def health_check():
    """Health check endpoint para Render"""
    return jsonify({
        "status": "healthy",
        "service": "Meross Timer API Mobile Simple v2.1",
        "platform": "render",
        "timestamp": datetime.now(SPAIN_TZ).isoformat(),
        "api_type": "mobile_simple",
        "features": [
            "Mobile API simulation (requests only)",
            "Android headers spoofing", 
            "Simple session management",
            "Timer scheduling",
            "Job management", 
            "Connection caching",
            "Error recovery",
            "Manual cache clearing",
            "Mobile connection testing",
            "Python 3.13 compatible"
        ]
    })

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    log_message(f"📱 Iniciando Meross Timer API Mobile Simple v2.1 en puerto {port}")
    app.run(host='0.0.0.0', port=port)
