package examplepack;

@:build(HaxeCInterface.build())
class ExampleClass {

	static public function example(): String {
		return "example-works";
	}

}

@:build(HaxeCInterface.build())
private class ExampleClassPrivate {

	static public function examplePrivate(): String {
		return "example-private-works";
	}

}