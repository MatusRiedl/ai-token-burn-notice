' Starts AI Burn Notice with no console window. Arguments (e.g. -show) are passed to tray.ps1.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
args = ""
For Each a In WScript.Arguments
    args = args & " " & a
Next
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\tray.ps1""" & args, 0, False
