package pack;

@:build(HaxeEmbed.build())
class ExampleClass {

	static public function example(): String {
		return "example-works";
	}

}

@:build(HaxeEmbed.build())
private class ExampleClassPrivate {

	static public function examplePrivate(): String {
		return "example-private-works";
	}

}