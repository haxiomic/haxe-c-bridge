package pack;

@:build(HaxeEmbed.build())
class ExampleClass {

	static public function example(): cpp.ConstCharStar {
		return "example-works";
	}

}

@:build(HaxeEmbed.build())
private class ExampleClassPrivate {

	static public function examplePrivate(): cpp.ConstCharStar {
		return "example-private-works";
	}

}