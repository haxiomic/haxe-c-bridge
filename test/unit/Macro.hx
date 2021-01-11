import haxe.macro.Context;

class Macro {

	static public macro function getHaxeVersion() {
		return macro $v{Context.definedValue('haxe')};
	}

	static public macro function getHxcppVersion() {
		return macro $v{Context.definedValue('hxcpp')};
	}

}