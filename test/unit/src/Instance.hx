class Base {
	public function overrideMe(): String throw 'should be overridden';
}

@:build(HaxeCBridge.expose())
class Instance extends Base {

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

	override public function overrideMe() {
		return str;
	}

	function privateMethod() {

	}

	static public function staticMethod() {

	}

}