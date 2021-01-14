package pack;

@:build(HaxeCBridge.build())
class ExampleClass {

	static function main() {
		trace('alternative main!');
	}

	static public function example(): Int {
		return 1;
	}

}

@:build(HaxeCBridge.build())
@:nativeGen // test nativeGen doesn't interfere with c-api macro
private class ExampleClassPrivate {

	static public function examplePrivate(): Int {
		return 2;
	}

}