# Haxe C Bridge

**WIP – not ready to use – docs coming soon!**

HaxeCBridge is a `@:build` macro that allows you to call haxe code from C by exposing static functions via an automatically generated C header

A separate thread is used to host the haxe execution and the haxe event loop so events and multi-threaded code. When calling haxe functions from C, the haxe code is executed synchronously on the haxe thread (unless the function is marked with `@externalThread`)

Requires haxe 4.2 and hxcpp

use `-D dll_link` or `-D static_link` to generate a native library