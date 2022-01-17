@REM run this script in an x64 visual studio command prompt  

@REM build haxe code
haxe build-library.hxml || exit /b

@REM compile app.c to app.exe
cl .\app.c /I .\haxe-bin\ /Zi /link .\haxe-bin\obj\lib\Main-debug.lib /DEBUG || exit /b

@REM copy the library dll locally for running
copy haxe-bin\Main-debug.dll Main-debug.dll
@REM copy the debugging info locally
copy .\haxe-bin\obj\lib\Main-debug.pdb Main-debug.pdb

@REM run app.exe
app.exe