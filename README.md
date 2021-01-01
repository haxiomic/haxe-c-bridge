# HaxeEmbed

Interface with a multi-threaded hxcpp haxe program from C via message passing

**Requires haxe 4.2 and hxcpp**

## Usage
In your haxe `main()`, call `HaxeEmbed.setMessageHandler(your-handler-function)` to receive messages from native code

In your native C code, include `include/HaxeEmbed.h` from the hxcpp generated code and call:
- `HaxeEmbed_startHaxeThread(exceptionCallback)` to start the haxe thread
- `HaxeEmbed_sendMessageSync(type, data)` to queue a message on the haxe thread and block until it is handled
- `HaxeEmbed_sendMessageAsync(type, data, onComplete)` to queue a message on the haxe thread, return immediately and execute the callback when the message has been handled
- `HaxeEmbed_stopHaxeThread()` to end the haxe thread

See [HaxeEmbed.h](./HaxeEmbed.h) for more documentation and [examples/](./examples/) for commented example code