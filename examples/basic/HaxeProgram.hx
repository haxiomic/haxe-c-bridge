import cpp.Callable;
import cpp.Function;
import cpp.RawPointer;
import cpp.ConstCharStar;
import sys.thread.Thread;
import sys.thread.Lock;
import haxe.Timer;
import cpp.Star;

	// <compilerflag value="-fsanitize=thread" />
/**/
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

	static var num = 0;
	static var loopCount = 0;
	static var nativeCallback: cpp.Callable<() -> Void> = new Callable(null);
	static var x: Star<cpp.Void> = null;

	static function main() {
		trace('haxe main() ${num++} $nativeCallback');

		// register a callback to receive messages from native calls
		HaxeEmbed.setMessageHandler(onMessage);

		// check the haxe-thread's event loop is working
		Timer.delay(() -> {
			trace('delay 3000 complete');
		}, 3000);

		function loop() {
			trace('loop $loopCount $nativeCallback');
			if (nativeCallback != null) {
				nativeCallback();
			}
			loopCount++;
			Timer.delay(loop, 500);
		}
		loop();
	}
	
	static final retStr = 'string from haxe!';

	static function onMessage(type: String, data: Dynamic): Star<cpp.Void> {
		trace('Got message of type $type ($data)');
		
		switch type {
			case 'SET-NATIVE-CALLBACK':
				nativeCallback = cast data;

			case 'NUMBER':
				var num: cpp.Pointer<Int> = data;
				trace('number is ${num[0]}');

			case 'TRIGGER-EXCEPTION':
				throw "Here's a haxe runtime exception";

			default:
				var num: cpp.Pointer<Int> = data;
				trace('Unknown native event "$type" ($num – ${num[0]}) ');
		}

		var cStr = ConstCharStar.fromString(retStr);
		return cast cStr;
	}


}