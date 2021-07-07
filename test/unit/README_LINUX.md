# Building for Linux with these Versions 

```
$ haxe -version
4.2.3
```
haxelib hxcpp version:
`4.2.1`

```
$ gcc --version
gcc (Ubuntu 9.3.0-17ubuntu1~20.04) 9.3.0
```
# Build Commands
Build the library with haxe:

`haxe build-library.hxml`

Compile the app.c file with gcc:

`gcc app.c -o main haxe-bin/Main-debug.dso -Wl,-rpath,haxe-bin/`

run the executable:

`./main`

# Issues
If you run the executable and get ths error:
```
==941129==ASan runtime does not come first in initial library list; you should either link runtime to your application or manually preload it with LD_PRELOAD.
```
Run this command:
```
export ASAN_OPTIONS=verify_asan_link_order=0
```

and rerun the executable:

`./main`

