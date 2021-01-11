package pack;

@:build(HaxeEmbed.build())
class ExampleClass {

	static public function example(): Int {
		return 1;
	}

}

@:build(HaxeEmbed.build())
@:nativeGen // test nativeGen doesn't interfere with c-api macro
private class ExampleClassPrivate {

	static public function examplePrivate(): Int {
		return 2;
	}

}