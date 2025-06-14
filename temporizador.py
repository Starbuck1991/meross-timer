# ... (código anterior hasta kodiplex_on_quick) ...

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
        # Si es POST, verificar API key
        if request.method == 'POST':
            data = request.get_json() or {}
            api_key = data.get('api_key')
            api_key_env = os.getenv('MEROSS_API_KEY')
            
            if api_key_env and api_key != api_key_env:
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
        
        # Ejecutar test en un hilo separado para no bloquear
        def test_async():
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                return loop.run_until_complete(test_meross_connection(email, password, test_job_id))
            finally:
                loop.close()
        
        result = test_async()
        return jsonify(result)
        
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

async def test_meross_connection(email, password, job_id):
    """Test de conexión asíncrono"""
    http_api_client = None
    manager = None
    
    try:
        log_message(f"🧪 [{job_id}] Probando conexión con Meross...")
        
        # Conectar
        http_api_client = await MerossHttpClient.async_from_user_password(
            email=email, 
            password=password,
            api_base_url='https://iotx-eu.meross.com'
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
            await device.async_update()
            device_list.append({
                "name": device.name,
                "type": device.type,
                "online": device.online_status,
                "state": "on" if device.is_on() else "off"
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
