' pipeline.vbs  —  Windows-only pipeline
'   Run with:  cscript //nologo pipeline.vbs
Option Explicit

Dim shell, fso, workDir, baseUrl
Dim cfgUser, cfgRepo, cfgBranch
Dim files, f, rc, psCmd, tmpDir, dotnetExe, runCmd

Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

' ---------- CONFIG ----------
cfgUser   = "YOUR_GITHUB_USERNAME"
cfgRepo   = "YOUR_REPO_NAME"
cfgBranch = "main"
' ----------------------------

baseUrl = "https://raw.githubusercontent.com/" & cfgUser & "/" & cfgRepo & "/" & cfgBranch
workDir = shell.ExpandEnvironmentStrings("%USERPROFILE%") & "\pipeline"

If Not fso.FolderExists(workDir) Then fso.CreateFolder(workDir)
shell.CurrentDirectory = workDir

' ---------- 0. curl.exe sanity ----------
rc = shell.Run("cmd /c where curl.exe >nul 2>nul", 0, True)
If rc <> 0 Then
    WScript.Echo "ERROR: curl.exe not found (Windows 10 1803+ ships it built-in)."
    WScript.Quit 1
End If

' ---------- 1. Download ----------
files = Array("auto.cs", "fake.cs")
For Each f In files
    WScript.Echo "-> Downloading " & f & " ..."
    rc = shell.Run( _
        "curl.exe -fsSL -o " & """" & workDir & "\" & f & """" & _
        " " & """" & baseUrl & "/" & f & """", _
        1, True)
    If rc <> 0 Then
        WScript.Echo "ERROR: curl failed for " & f & " (exit " & rc & ")"
        WScript.Quit 1
    End If
Next

' ---------- 2. Install .NET (user dir) ----------
tmpDir = shell.ExpandEnvironmentStrings("%TEMP%")
psCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " & """" & _
        "Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' " & _
        "-OutFile '" & tmpDir & "\dotnet-install.ps1'; " & _
        "& '" & tmpDir & "\dotnet-install.ps1' -Channel 10.0" & """"

WScript.Echo "-> Installing .NET (this can take a few minutes) ..."
rc = shell.Run(psCmd, 1, True)
If rc <> 0 Then
    WScript.Echo "ERROR: dotnet install failed (exit " & rc & ")"
    WScript.Quit 1
End If

' ---------- 3. Locate user-dir dotnet ----------
dotnetExe = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Microsoft\dotnet\dotnet.exe"
If Not fso.FileExists(dotnetExe) Then
    WScript.Echo "ERROR: dotnet.exe not found at " & dotnetExe
    WScript.Quit 1
End If

' ---------- 4. Run app ----------
runCmd = """" & dotnetExe & """" & _
         " run --file " & """" & workDir & "\auto.cs" & """" & _
         " -- " & """" & workDir & "\fake.cs" & """"

WScript.Echo "-> Running: " & runCmd
rc = shell.Run(runCmd, 1, True)
If rc <> 0 Then
    WScript.Echo "ERROR: dotnet run failed (exit " & rc & ")"
    WScript.Quit rc
End If

WScript.Echo "Done."
