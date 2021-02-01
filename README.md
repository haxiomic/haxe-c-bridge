# Haxe C Bridge

HaxeCBridge is a `@:build` macro that enables calling haxe code from C by exposing classes via an automatically generated C header. This makes it possible to build your user interfaces using native platform tools (like Swift and Java) and call into haxe code for the main app work like rendering

**Requires haxe 4.0 or newer and hxcpp**

## Quick Start

Install with `haxelib install haxe-c-bridge` (or simply copy the `HaxeCBridge.hx` file into your root class-path)

Haxe-side:
- Add `--library haxe-c-bridge` to your hxml
- Add `-D dll_link` or `-D static_link` to your hxml to compile your haxe program into a native library binary
- Add `@:build(HaxeCBridge.expose())` to classes that you want to expose to C (you can add this to as many classes as you like – all functions are combined into a single header file)
- HaxeCBridge will then generate a header file in your build output directory named after your `--main` class (however a `--main` class is not required to use HaxeCBridge)

C-side:
- `#include` the generated header and link with the hxcpp generated library binary
- Before calling any haxe functions you must start the haxe thread: call `YourLibName_initializeHaxeThread(onHaxeException)`
- Now interact with your haxe library thread by calling the exposed functions
- When your program exits call `YourLibName_stopHaxeThread(true)`

See [test/unit](test/unit) for a complete example

## Minimal Example

**Main.hx**
```haxe
class Main {
	static function main() {
		trace("haxe thread started!");
	}
}

@:build(HaxeCBridge.expose())
class UseMeFromC {

	final callback: (num: Int) -> Void;

	// to expose haxe callbacks to C we wrap them in cpp.Callback<T>
	public function new(exampleCallback: cpp.Callable<(num: Int) -> Void>) {
		callback = (num) -> exampleCallback(num);
	}

	public function add(a: Int, b: Int) {
		var result = a + b;
		callback(result);
		return result;
	}

	static public function exampleStaticFunction() {
		return "here's a string from haxe! In C this will be represented as a const char*. When passing haxe object to C, the object will be retained so it's not garbage collected while it's being used in C. When finished with haxe objects, you can call releaseHaxeString() or releaseHaxeObject()";
	}

}
```

**build.hxml**
```hxml
--main Main
--cpp bin
--dce full
-D dll_link
```

Then run `haxe build.hxml` to compile the haxe code into a native library binary

This will generate a header file: `bin/Main.h` with our haxe function exposed as:
```C
HaxeObject Main_UseMeFromC_new(function_Int_Void exampleCallback);
int Main_UseMeFromC_add(HaxeObject instance, int a, int b);
HaxeString Main_UseMeFromC_exampleStaticFunction();
```

We can use our class from C like so:
```C
void onHaxeException(const char* info) {
	printf("Haxe exception: \"%s\"\n", info);
	// stop the haxe thread immediately
	Main_stopHaxeThreadIfRunning(false);
}

void exampleCallback(int num) {
	printf("exampleCallback(%d)\n", num);
}

int main(void) {
	// start the haxe thread
	Main_initializeHaxeThread(onHaxeException);

	// create an instance of our haxe class
	HaxeObject instance = Main_UseMeFromC_new(exampleCallback);
	// to call members of instance, we pass the instance in as the first argument
	int result = Main_UseMeFromC_add(instance, 1, 2);
	// when we're done with our object we can tell the haxe-gc we're finished
	Main_releaseHaxeObject(instance);

	// call a static function
	HaxeString cStr = Main_UseMeFromC_exampleStaticFunction();
	printf("%s\n", cStr);
	Main_releaseHaxeString(cStr);

	// stop the haxe thread but wait for any scheduled events to complete
	Main_stopHaxeThreadIfRunning(true);

	return 0;
}
```

## Background

C is a common language many platforms use to glue to one another. It's always been relatively easy to call C code from haxe using haxe C++ externs (or simply [`untyped __cpp__('c-code')`](https://haxe.org/manual/target-syntax.html)) but it's much harder to call haxe code from C: while hxcpp can generate C++ declarations with [`@:nativeGen`](https://github.com/HaxeFoundation/hxcpp/blob/master/test/extern-lib/api/HaxeApi.hx), you need to manually create adaptors for these to use with C. Additionally you have to take care to manage the haxe event loop and interaction with the haxe garbage collector. 

This library plugs that gap by automatically generating safe function bindings, managing the event loop and taking care of converting exposed types to be C compatible and GC-safe.

A separate thread is used to host the haxe execution and the haxe event loop so events scheduled in haxe will continue running in parallel to the rest of your native app. When calling haxe functions from C, the haxe code will be executed synchronously on this haxe thread so it's safe for functions exposed to C to interact with the rest of your haxe code. You can disable haxe thread synchronization by adding `@externalThread` however this is less safe and you must then perform main thread synchronization yourself.

## Meta
- `@HaxeCBridge.name` – Can be used on functions and classes. On classes it sets the class prefix for each generated function and on functions it sets the complete function name (overriding prefixes)
- `@externalThread` – Can be used on functions. When calling a haxe function with this metadata from C that function will be executed in the haxe calling thread, rather than the haxe main thread. This is faster but less safe – you cannot interact with any other haxe code without first synchronizing with the haxe main thread (or your app is likely to crash)

## Compiler Defines
- `-D HaxeCBridge.name=YourLibName` – Set the name of the generated header file as well as the prefix to all generated C types and functions
- `-D dll_link` – A [hxcpp define](https://haxe.org/manual/target-cpp-defines.html) to compile your haxe code into a dynamic library (.dll, .dylib or .so on windows, mac and linux)
- `-D static_link` – A [hxcpp define](https://haxe.org/manual/target-cpp-defines.html) to compile your haxe code into a static library (.lib on windows or .a on mac and linux)

