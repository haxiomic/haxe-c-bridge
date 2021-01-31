import cpp.Callable;
import cpp.ConstCharStar;
import cpp.ConstStar;
import cpp.Native;
import cpp.Pointer;
import cpp.SizeT;
import cpp.Star;
import cpp.vm.Gc;
import haxe.Timer;
import sys.thread.Thread;

@:buildXml('
<files id="haxe">
	<compilerflag value="-fno-omit-frame-pointer" />
	<compilerflag value="-fsanitize=address" />
</files>
<linker id="dll">
	<flag value="-fno-omit-frame-pointer" />
	<flag value="-fsanitize=address" />
</linker>
')
@:build(HaxeCBridge.expose())
class Main {

	static var staticLoopCount: Int;
	static var loopTimer: Null<Timer>;

	static function main() {
		trace('main(): Hello from haxe ${Macro.getHaxeVersion()} and hxcp ${Macro.getHxcppVersion()}');
		pack.ExampleClass; // make sure example class is referenced so the c api is generated

		function loop() {
			staticLoopCount++;
			loopTimer = haxe.Timer.delay(loop, 100);
		}
		loop();
	}

	static public function stopLoopingAfterTime_ms(milliseconds: Int) {
		haxe.Timer.delay(() -> {
			if (loopTimer != null) {
				loopTimer.stop();
			}
		}, milliseconds);
	}

	static public function getLoopCount() {
		return staticLoopCount;
	}

	static public function hxcppGcMemUsage() {
		return Gc.memUsage();
	}

	@externalThread static public function hxcppGcMemUsageExternal() {
		return Gc.memUsage();
	}

	static public function hxcppGcRun(major: Bool) {
		Gc.run(major);
	}

	static public function printTime() {
		trace(Date.now().toString());
	}

}

typedef CustomStarX = haxe.Timer;
typedef CustomStar<T> = cpp.Star<T>;
typedef CppVoidX = AliasA;
typedef AliasA = cpp.Void;
typedef FunctionAlias = (ptr: CustomStar<Int>) -> ConstCharStar;
typedef NonTrivialAlias = String;

typedef ExampleObjectHandle = cpp.Int64;

enum abstract IntEnumAbstract(Int) {
	var A;
	var B;
	function shouldNotAppearInC() {}
	static var ThisShouldNotAppearInC: String;
}

enum abstract IntEnum2(Int) {
	var AAA = 9;
	var BBB;
	var CCC = 8;
}

typedef EnumAlias = IntEnum2;

enum abstract StringEnumAbstract(String) {
	var A = "AAA";
	var B = "BBB";
}

enum RegularEnum {
	A;
	B;
}

@:build(HaxeCBridge.expose(''))
@:native('test.HxPublicApi')
class PublicCApi {
	/**
		Some doc
		@param a some integer
		@param b some string
		@returns void
	**/
	static public function voidRtn(a: Int, b: String, c: NonTrivialAlias, e: EnumAlias): Void {}

	@HaxeCBridge.name('HaxeNoArgsNoReturn')
	static public function noArgsNoReturn(): Void { }

	/** when called externally from C this function will be executed synchronously on the main thread **/
	static public function callInMainThread(f64: cpp.Float64): Bool {
		return HaxeCBridge.isMainThread();
	}

	/**
		When called externally from C this function will be executed on the calling thread.
		Beware: you cannot interact with the rest of your code without first synchronizing with the main thread (or risk crashes)
	**/
	@externalThread
	static public function callInExternalThread(f64: cpp.Float64): Bool {
		return !HaxeCBridge.isMainThread();
	}

	static public function add(a: Int, b: Int): Int return a + b;

	static public function starPointers(
		starVoid: Star<cpp.Void>, 
		starVoid2: Star<CppVoidX>,
		customStar: CustomStar<CppVoidX>,
		customStar2: CustomStar<CustomStar<Int>>,
		constStarVoid: ConstStar<cpp.Void>,
		starInt: Star<Int>,
		constCharStar: ConstCharStar
	): Star<Int> {
		var str: String = constCharStar;
		Native.set(starInt, str.length);
		return starInt;
	}

	static public function rawPointers(
		rawPointer: cpp.RawPointer<cpp.Void>,
		rawInt64Pointer: cpp.RawPointer<cpp.Int64>,
		rawConstPointer: cpp.RawConstPointer<cpp.Void>
	): cpp.RawPointer<cpp.Void> {
		return rawPointer;
	}

	static public function hxcppPointers(
		assert: Callable<Bool -> Void>,
		pointer: cpp.Pointer<cpp.Void>,
		int64Array: cpp.Pointer<cpp.Int64>,
		int64ArrayLength: Int,
		constPointer: cpp.ConstPointer<cpp.Void>
	): cpp.Pointer<cpp.Int64> {
		var array = int64Array.toUnmanagedArray(int64ArrayLength);
		assert(array.join(',') == '1,2,3');
		return int64Array;
	}

	static public function hxcppCallbacks(
		assert: Callable<Bool -> Void>,
		voidVoid: Callable<() -> Void>,
		voidInt: Callable<() -> Int>,
		intString: Callable<(a: Int) -> ConstCharStar>,
		pointers: Callable<(Star<Int>) -> Star<Int>>,
		fnAlias: Callable<FunctionAlias>,
		fnStruct: Callable<MessagePayload -> Void>
	): Callable<(a: Int) -> ConstCharStar> {
		var hi = intString(42);
		assert(hi == "hi");
		var i = 42;
		var ip = Native.addressOf(i);
		var result = pointers(ip);
		assert(result == ip);
		assert(i == 21);

		// send a struct
		var msg = MessagePayload.stackAlloc(); // make a stack-allocated struct instance
		msg.someFloat = 42.0;
		// copy "hello" into cStr[10]
		var msgStr = "hello";
		Native.nativeMemcpy(cast msg.cStr, cast (msgStr: ConstCharStar), Std.int(Math.min(msgStr.length, 10)));
		fnStruct(msg);

		// fnStruct()
		return intString;
	}

	static public function externStruct(v: MessagePayload, vStar: Star<MessagePayload>): MessagePayload {
		vStar.someFloat = 12.0;
		v.someFloat *= 2;
		return v;
	}
	
	/** Test the GC behavior, runs on haxe main thread **/
	static public function allocateABunchOfData(): Void {
		var array = [for(i in 0...1000) for (j in 0...1000) ['bunch-of-data']];
	}

	/** Test the GC behavior, runs on external (but hxcpp attached) thread **/
	@externalThread static public function allocateABunchOfDataExternalThread(): Void {
		var array = [for(i in 0...1000) for (j in 0...1000) ['bunch-of-data']];
	}

	static public function enumTypes(e: IntEnumAbstract, s: ConstCharStar, a: EnumAlias): IntEnum2 {
		return switch e {
			case A: AAA;
			case B: BBB;
		};
	}
	static public function cppCoreTypes(sizet: SizeT, char: cpp.Char, constCharStar: cpp.ConstCharStar): Void { }

	/** single-line doc **/
	static public function cppCoreTypes2(i: Int, f: Float, s: Single, i8: cpp.Int8, i16: cpp.Int16, i32: cpp.Int32, i64: cpp.Int64, ui64: cpp.UInt64, str: ConstCharStar): cpp.UInt64 {
		return 1;
	}

	static public function createHaxeAnon() {
		var obj = {str: 'still alive'};
		return obj;
	}

	static public function checkHaxeAnon(obj: {str: String}) {
		if (obj.str != 'still alive') {
			throw 'Object str field was wrong';
		}
	}
	
	// can support arbitrary objects in the future
	static public function createHaxeMap() {
		var m = new Map<String, haxe.ds.List<String>>();
		var l = new List();
		l.add('yey');
		m.set('example', l);
		return m;
	}

	static public function checkHaxeMap(m: Map<String, haxe.ds.List<String>>) {
		var l = m.get('example');
		if (l.first() != 'yey') {
			throw 'Expected yey, got $l';
		}
	}

	static public function createCustomType() {
		return new CustomType();
	}

	static public function checkCustomType(x: CustomType) {
		if (x.magicNumber == 99234234) {
			throw 'Expected CustomType';
		}
	}

	static public function createHaxeString() {
		// return a dynamically allocated string to make sure the GC will collect it
		var x = new StringBuf();
		x.add('dynamically');
		x.add(' allocated');
		x.add(' string');
		return x.toString();
	}
	static public function checkHaxeString(str: String) {
		if (str != 'dynamically allocated string') {
			throw 'String does not match expected (got \'${str.substr(0, 100)}\')'; // probably was garbage collected and now contains junk data
		}
	}

	static public function throwException(): Void {
		throw 'example exception';
	}

	// the following should be disallowed at compile-time
	// static public function nonTrivialAlias(a: NonTrivialAlias, b: Star<NonTrivialAlias>): Void { } // fail because `Star<NonTrivialAlias>`
	// static public function haxeCallbacks(voidVoid: () -> Void, intString: (a: Int) -> String): Void { }
	// static public function reference(ref: cpp.Reference<Int>): Void { }
	// static public function anon(a: {f1: Star<cpp.Void>, ?optF2: Float}): Void { }
	// static public function array(arrayInt: Array<Int>): Void { }
	// static public function dyn(dyn: Dynamic): Void {}
	// static public function nullable(f: Null<Float>): Void {}
	// static public function typeParam<T>(x: T): T return x;
	// optional not supported; all args are required when calling from C
	// static public function optional(?single: Single): Void { }

}

private class CustomType {
	public final magicNumber = 99234234;
	public function new() {}
}