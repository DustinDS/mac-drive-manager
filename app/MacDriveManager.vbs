' Launches Mac Drive Manager with no console window.
' Locates the PowerShell script relative to itself, so the repo can live anywhere.
Dim fso, sh, here, ps1
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = fso.BuildPath(here, "MacDriveManager.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "Could not find:" & vbCrLf & ps1, vbCritical, "Mac Drive Manager"
    WScript.Quit 1
End If

sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
