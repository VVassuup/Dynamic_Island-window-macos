@echo off
chcp 65001 >nul
echo Building Dynamic Island...
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o publish
if %errorlevel% neq 0 (
  echo.
  echo Build failed. Install .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0
  pause
  exit /b 1
)
echo.
echo Done! Run publish\DynamicIsland.exe
start "" "publish\DynamicIsland.exe"
