# Haxe C Bridge

HaxeCBridge is a `@:build` macro that enables calling haxe code from C by exposing static functions via an automatically generated C header

**Requires haxe 4.0 or newer and hxcpp**

## Quick Start

Install with `haxelib install haxe-c-bridge` (or simply copy the `HaxeCBridge.hx` file into your root class-path)

Haxe-side:
- Add `@:build(HaxeCBridge.build())` to a classes containing *static* *public* functions you want to expose to C
- Add `-D dll_link` or `-D static_link` to your `--cpp` build hxml to compile your haxe program into a native library binary
- HaxeCBridge will then generate a header file in your build output directory named after your `--main` class (however a `--main` class is not required to use HaxeCBridge)

C-side:
- Include the generated header and link with the hxcpp generated library binary
- Before calling any haxe functions you must start the haxe thread: call `YourLibName_initializeHaxeThread(onHaxeException)`
- Now interact with your haxe library thread by calling the exposed functions
- When your program exits call `YourLibName_stopHaxeThread(true)`

See [test/unit](test/unit) for an example

## Theory

C is a common language many platforms use to glue to one another. It's always been relatively easy to call C code from haxe using haxe C++ externs (or simply [untyped __cpp__('c-code')](https://haxe.org/manual/target-syntax.html)) but it's much harder to call haxe code from C: while hxcpp can generate C++ declarations with [`@:nativeGen`](https://github.com/HaxeFoundation/hxcpp/blob/master/test/extern-lib/api/HaxeApi.hx), you need to manually create C adaptors to bind to haxe functions. Additionally you have to take care to manage the haxe event loop and haxe garbage collector. 

This library plugs that gap by automatically generating safe function bindings, managing the event loop and taking care of converting exposed types to be C compatible.

A separate thread is used to host the haxe execution and the haxe event loop (so events scheduled in haxe will continue running in parallel to the rest of your native app). When calling haxe functions from C the haxe code will be executed synchronously on this haxe thread so it's safe for functions exposed to C to interact with the rest of your haxe code. You can disable haxe thread synchronization by adding `@externalThread` however this is less safe and you must then perform main thread synchronization yourself.

## Meta
- `@HaxeCBridge.name` – Can be used on functions and classes. On classes it sets the class prefix for each generated function and on functions it sets the complete function name (overriding prefixes)
- `@externalThread` – Can be used on functions. When calling a haxe function with this metadata from C that function will be executed in the haxe calling thread, rather than the haxe main thread. This is faster but less safe – you cannot interact with any other haxe code without first synchronizing with the haxe main thread (or your app is likely to crash)

## Compiler Defines
- `-D HaxeCBridge.name=YourLibName` – Set the name of the generated header file as well as the prefix to all generated C types and functions
- `-D dll_link` – A [hxcpp define](https://haxe.org/manual/target-cpp-defines.html) to compile your haxe code into a dynamic library (.dll, .dylib or .so on windows, mac and linux)
- `-D static_link` – A [hxcpp define](https://haxe.org/manual/target-cpp-defines.html) to compile your haxe code into a static library (.lib on windows or .a on mac and linux)

