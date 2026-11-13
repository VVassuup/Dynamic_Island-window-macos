@echo off
cd /d "%~dp0"
echo ============================================
echo   Dynamic Island - installer build
echo   created by Wassup
echo ============================================
echo.
echo [1/2] Publishing app (self-contained, win-x64)...
if exist publish\installer rmdir /s /q publish\installer
dotnet publish DynamicIsland.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=none -o publish\installer
if errorlevel 1 goto :buildfail

set "ISCC="
if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if exist "%LocalAppData%\Programs\Inno Setup 6\ISCC.exe" set "ISCC=%LocalAppData%\Programs\Inno Setup 6\ISCC.exe"
if not defined ISCC goto :noinno

echo.
echo [2/2] Building installer...
"%ISCC%" installer\DynamicIsland.iss
if errorlevel 1 goto :innofail

echo.
echo Done: dist\DynamicIsland_Setup_4.0.0.exe
start "" explorer dist
pause
exit /b 0

:buildfail
echo.
echo Build failed. Install .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0
pause
exit /b 1

:noinno
echo.
echo Inno Setup 6 not found. Install it: https://jrsoftware.org/isdl.php
echo or run: winget install JRSoftware.InnoSetup
pause
exit /b 1

:innofail
echo.
echo Inno Setup compile failed - see the messages above.
pause
exit /b 1
