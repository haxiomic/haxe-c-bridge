import cpp.Native;
import cpp.Callable;
import cpp.Function;
import cpp.RawPointer;
import cpp.ConstCharStar;
import sys.thread.Thread;
import sys.thread.Lock;
import haxe.Timer;
import cpp.Star;

// uncomment to enable address-sanitizer for clang or gcc
/**
@:buildXml('
<files id="haxe">
	<compilerflag value="-fno-omit-frame-pointer" />
	<compilerflag value="-fsanitize=address" />
</files>
<linker id="dll">
	<flag value="-fno-omit-frame-pointer" />
	<flag value="-fsanitize=address" />
</linker>
')
/**/
class HaxeProgram {

	// demonstrating static vars are lost if the haxe thread is shutdown
	static var incrementingStaticVar = 0;
	static var loopCount = 0;
	static var nativeCallback: cpp.Callable<Int -> Void> = new Callable(null);

	// number is set from native code by sending a message with type 'NUMBER'
	static var number: Int = -1;

	static function main() {
		trace('HaxeProgram.main()');

		// register a callback to receive messages from native calls
		HaxeEmbed.setMessageHandler(onMessage);

		// check the haxe-thread's event loop is working
		Timer.delay(() -> {
			trace('delay 3000 complete');
		}, 3000);

		function loop() {
			trace('loop $loopCount');
			if (nativeCallback != null) {
				nativeCallback(loopCount);
			}
			loopCount++;
			Timer.delay(loop, 500);
		}
		loop();
	}
	
	static final messageReply = 'string from haxe!';

	static function onMessage(type: String, data: Dynamic): Star<cpp.Void> {
		// trace('Got message of type $type ($data)');
		
		switch type {
			case 'SET-NATIVE-CALLBACK':
				// set a native code callback so haxe can call into native code
				nativeCallback = cast data;

			case 'NUMBER':
				var numPointer: cpp.Pointer<Int> = data;
				number = numPointer[0];
				trace('Number message: ${number}');

			case 'ASYNC-MESSAGE':
				var payload: Star<MessagePayload> = data;
				trace('Async message payload: ${payload.someFloat}, ${payload.cStr}');

			case 'TRIGGER-EXCEPTION':
				// this will kill the haxe main thread because the exception is unhandled
				// the user can get unhandled exception info by providing a callback when starting the haxe thread
				throw "Here's a haxe runtime exception :)";

			default:
				var num: cpp.Pointer<Int> = data;
				trace('Unknown native event "$type" ($num – ${num[0]}) ');
		}

		// for all messages, return our string to demonstrate message replies
		var cStr = ConstCharStar.fromString(messageReply);
		return cast cStr;
	}

}