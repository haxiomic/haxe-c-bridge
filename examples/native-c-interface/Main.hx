import cpp.Callable;
import cpp.ConstCharStar;
import cpp.ConstStar;
import cpp.Pointer;
import cpp.SizeT;
import cpp.Star;
import examplepack.ExampleClass;
import haxe.EntryPoint;
import sys.thread.Thread;

class Main {

	static function main() {
		ExampleClass;
	}

}

typedef CustomStar<T> = cpp.Star<T>;
typedef CppVoidX = AliasA;
typedef AliasA = cpp.Void;
typedef FunctionAlias = (ptr: CustomStar<Int>) -> String;

enum abstract IntEnumAbstract(Int) {
	var A;
	var B;
	function shouldNotAppearInC() {}
	static var ThisShouldNotAppearInC: String;
}

enum abstract IndirectlyReferencedEnum(Int) {
	var AAA;
	var BBB;
}

enum abstract StringEnumAbstract(String) {
	var A = "AAA";
	var B = "BBB";
}


enum RegularEnum {
	A;
	B;
}

@:build(HaxeCInterface.build())
@:native('test.HxPublicApi')
class PublicApi {

	static public function starPointers(
		starVoid: Star<cpp.Void>, 
		starVoid2: Star<CppVoidX>,
		customStar: CustomStar<CppVoidX>,
		customStar2: CustomStar<CustomStar<Int>>,
		constStarVoid: ConstStar<cpp.Void>,
		starInt: Star<Int>,
		constCharStar: ConstCharStar
	): Void { }

	static public function rawPointers(
		rawPointer: cpp.RawPointer<cpp.Void>,
		rawInt64Pointer: cpp.RawPointer<cpp.Int64>,
		rawConstPointer: cpp.RawConstPointer<cpp.Void>
	): Void { }

	static public function hxcppPointers(
		pointer: cpp.Pointer<cpp.Void>,
		int64Pointer: cpp.Pointer<cpp.Int64>,
		constPointer: cpp.ConstPointer<cpp.Void>
	): Void { }

	static public function hxcppCallbacks(
		voidVoid: Callable<() -> Void>,
		voidInt: Callable<() -> Int>,
		intString: Callable<(a: Int) -> String>,
		stringInt: Callable<(String) -> Int>,
		intVoid: Callable<(Int) -> Void>,
		pointers: Callable<(Pointer<Int>) -> Pointer<Int>>,
		fnAlias: Callable<FunctionAlias>
	): Callable<() -> Void> {
		return voidVoid;
	}

	static public function externStruct(v: MessagePayload): MessagePayload return v;

	static public function optional(?single: Single): Void { }
	static public function badOptional(?opt: Single, notOpt: Single): Void { }

	static public function enumTypes(e: IntEnumAbstract, s: StringEnumAbstract, i: Star<IndirectlyReferencedEnum>, ii: Star<Star<IndirectlyReferencedEnum>>): Void { }
	static public function cppCoreTypes(sizet: SizeT, char: cpp.Char, constCharStar: cpp.ConstCharStar): Void { }

	static public function add(a: Int, b: Int): Int return a + b;
	
	/** single-line doc **/
	static public function somePublicMethod(i: Int, f: Float, s: Single, i8: cpp.Int8, i16: cpp.Int16, i32: cpp.Int32, i64: cpp.Int64, ui64: cpp.UInt64, str: String): Int {
		trace('somePublicMethod()');
		return -1;
	}

	/**
		Some doc
		@param a some integer
		@param b some string
		@returns void
	**/
	static public function voidRtn(a: Int, b: String): Void {
		trace('voidRtn()');
	}

	static public function noArgsNoReturn(): Void {}

	@externalThread
	static public function callInExternalThread(f64: cpp.Float64): Bool {
		return HaxeCInterface.isMainThread();
	}

	// the following should be disallowed at compile-time
	// static public function haxeCallbacks(voidVoid: () -> Void, intString: (a: Int) -> String): Void { }
	// static public function reference(ref: cpp.Reference<Int>): Void { }
	// static public function anon(a: {f1: Star<cpp.Void>, ?optF2: Float}): Void { }
	// static public function array(arrayInt: Array<Int>): Void { }
	// static public function nullable(f: Null<Float>): Void {}
	// static public function dyn(dyn: Dynamic): Void {}

}