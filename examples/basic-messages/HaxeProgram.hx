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

	static var loopCount = 0;
	static var nativeCallback: cpp.Callable<Int -> Void> = new Callable(null);

	static function main() {
		trace('HaxeProgram.main()');

		// register a callback to receive messages from native calls
		HaxeEmbed.setMessageHandler(onMessage);

		// check the haxe-thread's event loop is working
		// this will add a pending event scheduled in the future, but it should not prevent the haxe thread from ending
		Timer.delay(() -> trace('delay 3s complete'), 3000);
		Timer.delay(() -> trace('delay 4s complete'), 4000);// if main.c sleeps for only 3s before stopping the haxe thread, this should never be executed

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

		switch type {
			case 'SET-NATIVE-CALLBACK':
				// set a native code callback so haxe can call into native code
				nativeCallback = cast data;

			case 'NUMBER':
				var numPointer: cpp.Pointer<Int> = data;
				var number = numPointer[0];
				trace('Number message: ${number}');

			case 'ASYNC-MESSAGE':
				var payload: Star<MessagePayload> = data;
				trace('Async message payload: ${payload.someFloat}, ${payload.cStr}');

			case 'TRIGGER-EXCEPTION':
				// this will kill the haxe main thread because the exception is unhandled
				// the user can get unhandled exception info by providing a callback when starting the haxe thread
				throw "Here's a haxe runtime exception :)";

			default:
				trace('Unknown native event "$type"');
		}

		// for all messages, return our string to demonstrate message replies
		var cStr = ConstCharStar.fromString(messageReply);
		return cast cStr;
	}

}