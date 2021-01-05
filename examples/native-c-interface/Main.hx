import cpp.Callable;
import cpp.ConstCharStar;
import cpp.ConstStar;
import cpp.SizeT;
import cpp.Star;

class Main {

	static function main() {
	}

}

typedef CustomStar<T> = cpp.Star<T>;
typedef CppVoidX = AliasA;
typedef AliasA = cpp.Void;
typedef FunctionAlias = (ptr: CustomStar<Int>) -> String;

enum abstract IntEnumAbstract(Int) {
	var A;
	var B;
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
@:native('HxPublicApi')
@:expose
class PublicApi {

	static public function starPointers(
		starVoid: Star<cpp.Void>, 
		starVoid2: Star<CppVoidX>,
		customStar: CustomStar<CppVoidX>,
		customStar2: CustomStar<CustomStar<Int>>,
		constStarVoid: ConstStar<cpp.Void>,
		starInt: Star<Int>,
		constCharStar: ConstCharStar
	): Void {
		trace('starPointers()');
	}

	static public function rawPointers(
		rawPointer: cpp.RawPointer<cpp.Void>,
		rawInt64Pointer: cpp.RawPointer<cpp.Int64>,
		rawConstPointer: cpp.RawConstPointer<cpp.Void>
	): Void {
		trace('rawPointers()');
	}

	static public function hxcppPointers(
		pointer: cpp.Pointer<cpp.Void>,
		int64Pointer: cpp.Pointer<cpp.Int64>,
		constPointer: cpp.ConstPointer<cpp.Void>
	): Void {
		trace('hxcppPointers()');
	}

	// static public function haxeCallbacks(voidVoid: () -> Void, intString: (a: Int) -> String): Void { }

	static public function hxcppCallbacks(
		voidVoid: Callable<() -> Void>,
		voidInt: Callable<() -> Int>,
		intString: Callable<(a: Int) -> String>,
		intVoid: Callable<(Int) -> Void>,
		fnAlias: Callable<FunctionAlias>
	): Callable<() -> Void> {
		return voidVoid;
	}


	// static public function anon(a: {f1: Star<cpp.Void>, ?optF2: Float}): Void { }
	// static public function array(arrayInt: Array<Int>): Void { }
	// static public function nullable(f: Null<Float>): Void {}
	// static public function dynamic(dyn: Dynamic): Void {}

	// @! weird hxcpp issue
	// static public function externStruct(v: MessagePayload): MessagePayload return v;
	static public function externStruct(v: MessagePayload): Void { };

	static public function optional(?single: Single): Void { }
	static public function badOptional(?opt: Single, notOpt: Single): Void { }

	static public function someInterestingTypes(e: IntEnumAbstract, s: StringEnumAbstract /*, re: RegularEnum*/): Void { }
	static public function cppCoreTypes(sizet: SizeT, char: cpp.Char, constCharStar: cpp.ConstCharStar): Void { }

	static public function add(a: Int, b: Int): Int {
		return a + b;
	}

	// static public function reference(ref: cpp.Reference<Int>): Void {
	// 	trace('reference()');
	// }

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

	/*
	static public function somePublicMethod_ThreadSafeCApi(a: Int, b: String) {
		if (Thread.current() == @:privateAccess EntryPoint.mainThread) {
			return somePublicMethod(a, b);
		} else {
			var completionLock = new Lock();
			var rtn;
			EntryPoint.runInMainThread(() -> {
				try {
					rtn = somePublicMethod(a, b);
					completionLock.release();
				} catch(e: Any) {
					completionLock.release();
					throw e;
				}
			});
			completionLock.wait();
			return rtn;
		}

	}
	*/

}