Set WshShell = CreateObject("WScript.Shell") 
WshShell.Run chr(34) & "C:\ProgramData\flex-launcher\assets\scripts\restart.bat" & Chr(34), 0
Set WshShell = Nothing