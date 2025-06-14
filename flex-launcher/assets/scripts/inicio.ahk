; Script para AutoHotkey v2 para ocultar la barra de tareas y abrir Explorer

#Requires AutoHotkey v2.0

; Ocultar la barra de tareas
WinHide("ahk_class Shell_TrayWnd")

; Esperar unos segundos para asegurarse de que esté oculta
Sleep(1000)

; Abrir el Explorador de Windows
Run("explorer.exe")

; Opcional: Mostrar nuevamente la barra de tareas después de ejecutar Explorer
Sleep(3000)
WinShow("ahk_class Shell_TrayWnd")
