@:build(HaxeCBridge.expose())
class Instance {

	final number = 12345678;
	final str: String;

	public function new(exampleArg: String) {
		this.str = exampleArg;
	}

	public function methodNoArgs() {

	}

	public function methodAdd(a: Int, b: Int) {
		return a + b;
	}

	function privateMethod() {

	}

	static public function staticMethod() {

	}

}