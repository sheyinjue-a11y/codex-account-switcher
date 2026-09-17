Option Explicit
Dim shell, files, picker
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
picker = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "Start-ChatGPT.ps1")
If Not files.FileExists(picker) Then
    MsgBox "Start-ChatGPT.ps1 is missing. Restore the account picker files.", 16, "ChatGPT"
    WScript.Quit 1
End If
shell.Run "powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & picker & """", 0, False
