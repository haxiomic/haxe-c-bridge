# Haxe C Bridge

**WIP – not ready to use – docs coming soon!**

HaxeCBridge is a `@:build` macro that enables calling haxe code from C by exposing static functions via an automatically generated C header

A separate thread is used to host the haxe execution and the haxe event loop (so events scheduled in haxe will continue running in parallel to the rest of your native app). When calling haxe functions from C the haxe code will be executed synchronously on this haxe thread so it's safe for functions exposed to C to interact with the rest of your haxe code. You can disable haxe thread synchronization by adding `@externalThread` however this is less safe and you must then perform main thread synchronization yourself

**Requires haxe 4.2 and hxcpp**

use `-D dll_link` or `-D static_link` to generate a native library