@REM build haxe code
haxe build-library.hxml

@REM open this file in an x64 visual studio command prompt  
cl .\app.c /I .\haxe-bin\ /Zi /link .\haxe-bin\obj\lib\Main-debug.lib /DEBUG
@REM copy the dll locally
copy haxe-bin\Main-debug.dll Main-debug.dll
@REM copy the debugging info locally
copy .\haxe-bin\obj\lib\Main-debug.pdb Main-debug.pdb

@REM run app.exe
app.exe