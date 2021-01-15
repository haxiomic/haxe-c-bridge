/**
	HaxeCBridge

	A `@:build` macro to enable easy embedding of a multi-threaded haxe program within a native application via an automatically generated C header

	Works with the hxcpp target and requires haxe 4.0 or newer

	@author George Corney (haxiomic)
	@license MIT

	**Usage**

	Haxe-side:
	- Add `@:build(HaxeCBridge.build())` to a classes containing *public static* functions you want to expose to C
		- The first argument of build() sets generated C function name prefix: `build('Example')` or `build('')` for no prefix
	- Add `-D dll_link` or `-D static_link` to compile your haxe program into a native library binary
	- HaxeCBridge will then generate a header file in your build output directory named after your `--main` class (however a `--main` class is not required to use HaxeCBridge)
		- Change the generated library name by adding `-D HaxeCBridge.name=YourLibName` to your hxml

	C-side:
	- Include the generated header and link with the hxcpp generated library binary
	- Before calling any haxe functions you must start the haxe thread: call `YourLibName_initializeHaxeThread(onHaxeException)`
	- Now interact with your haxe library thread by calling the exposed functions
	- When your program exits call `YourLibName_stopHaxeThread(true)`
	
**/
#if (haxe_ver < 4.0) #error "Haxe 4.0 required" #end

#if macro

	// fast path for when code gen isn't required
	// disable this to get auto-complete when editing this file
	#if (display || display_details || target.name != cpp)

class HaxeCBridge {
	public static function build(?namespace: String)
		return haxe.macro.Context.getBuildFields();
	@:noCompletion
	static macro function runUserMain()
		return macro null;
}

	#else

import HaxeCBridge.CodeTools.*;
import haxe.ds.ReadOnlyArray;
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.PositionTools;
import haxe.macro.Printer;
import haxe.macro.Type;
import haxe.macro.TypeTools;
import haxe.macro.TypedExprTools;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

class HaxeCBridge {

	static final noOutput = Sys.args().has('--no-output');
	static final printer = new Printer();
	
	static var firstRun = true;

	static final libName = getLibNameFromHaxeArgs();
	static final compilerOutputDir = Compiler.getOutput();
	// paths relative to the compiler output directory
	static final headerPath = Path.join(['$libName.h']);
	static final implementationPath = Path.join(['src', '__HaxeCBridgeBindings__.cpp']);
	
	static final queuedClasses = new Array<{
		cls: Ref<ClassType>,
		namespace: String,
	}>();

	// conversion state
	static final headersRequiredForImplementation = new Array<CInclude>();
	static final cConversionContext = new CConverterContext({
		declarationPrefix: libName,
		generateTypedef: true,
		generateTypedefWithTypeParameters: false,
	});
	static final functionInfo = new Map<String, {
		hxcppName: String,
		field: ClassField,
		rootCTypes: {
			args: Array<CType>,
			ret: CType
		},
		pos: Position,
	}>();

	static public function build(?namespace: String) {
		var fields = Context.getBuildFields();

		// resolve runtime HaxeCBridge class to make sure it's generated
		// add @:buildXml to include generated code
		var HaxeCBridgeType = Context.resolveType(macro :HaxeCBridge, Context.currentPos());
		switch HaxeCBridgeType {
			case TInst(_.get().meta => meta, params):
				if (!meta.has(':buildXml')) {
					meta.add(':buildXml', [
						macro $v{code('
							<!-- HaxeCBridge -->
							<files id="haxe">
								<file name="$implementationPath">
									<depend name="$headerPath"/>
								</file>
							</files>
						')}
					], Context.currentPos());
				}
			default: throw 'Internal error';
		}

		queuedClasses.push({
			cls: Context.getLocalClass(),
			namespace: namespace
		});

		// add @:keep
		Context.getLocalClass().get().meta.add(':keep', [], Context.currentPos());

		if (firstRun) {
			// if (!isLibraryBuild()) {
				// Context.warning("HaxeCBridge: project is not compiled as a library – add -D dll_link or -D static_link to compile as a shared or static library", Context.currentPos());
			// }
			
			Context.onAfterTyping(_ -> {
				for (item in queuedClasses) {
					convertQueuedClass(item.cls.get(), item.namespace);
				}

				var header = generateHeader(cConversionContext, libName);
				var implementation = generateImplementation(cConversionContext, libName);

				function saveFile(path: String, content: String) {
					var directory = Path.directory(path);
					if (!FileSystem.exists(directory)) {
						FileSystem.createDirectory(directory);
					}
					// only save if there's a difference (save C++ compilation by not changing the file if not needed)
					if (FileSystem.exists(path)) {
						if (content == sys.io.File.getContent(path)) {
							return;
						}
					}
					sys.io.File.saveContent(path, content);	
				}

				if (!noOutput) {
					saveFile(Path.join([compilerOutputDir, headerPath]), header);
					saveFile(Path.join([compilerOutputDir, implementationPath]), implementation);
				}
			});

			firstRun = false;
		}

		return fields;
	}

	static function convertQueuedClass(cls: ClassType, namespace: String) {
		// determine the name of the class as generated by hxcpp
		var isNativeGen = cls.meta.has(':nativeGen');
		var nativeMeta = cls.meta.extract(':native')[0];
		var nativeMetaValue = nativeMeta != null ? ExprTools.getValue(nativeMeta.params[0]) : null;
		var nativeName = (nativeMetaValue != null ? nativeMetaValue : cls.pack.concat([cls.name]).join('.'));
		var nativeHxcppName = nativeName + (isNativeGen ? '' : '_obj');

		// determine the hxcpp generated header path for this class
		var typeHeaderPath = nativeName.split('.');
		headersRequiredForImplementation.push({path: Path.join(typeHeaderPath) + '.h', quoted: false});

		// prefix all functions with lib name and class path
		var classPrefix = cls.pack.concat([namespace == null ? cls.name : namespace]);

		var cNameMeta = getCNameMeta(cls.meta);

		var functionPrefix =
			if (cNameMeta != null)
				[cNameMeta];
			else 
				[libName]
				.concat(safeIdent(classPrefix.join('.')) != libName ? classPrefix : [])
				.filter(s -> s != '');

		for (f in cls.statics.get()) {
			var isConvertibleMethod = f.isPublic && !f.isExtern && switch f.kind {
				case FVar(_), FMethod(MethMacro): false; // skip macro methods
				case FMethod(_): true;
			}
			if (!isConvertibleMethod) continue;

			// f is public static function
			var fieldExpr = f.expr();
			switch fieldExpr.expr {
				case TFunction(tfunc):

					// add C function declaration
					var cNameMeta = getCNameMeta(f.meta);
					
					var cFuncName: String =
						if (cNameMeta != null)
							cNameMeta;
						else
							functionPrefix.concat([f.name]).join('_');

					var cleanDoc = f.doc != null ? StringTools.trim(removeIndentation(f.doc)) : null;
					cConversionContext.addTypedFunctionDeclaration(cFuncName, tfunc, cleanDoc, f.pos);

					inline function getRootCType(t: Type) {
						var tmpCtx = new CConverterContext({generateTypedef: false, generateTypedefForFunctions: false, generateEnums: true});
						return tmpCtx.convertType(t, true, true, f.pos);
					}

					// store useful information about this function that we can use when generating the implementation
					functionInfo.set(cFuncName, {
						hxcppName: nativeHxcppName.split('.').join('::') + '::' + f.name,
						field: f,
						rootCTypes: {
							args: tfunc.args.map(a -> getRootCType(a.v.t)),
							ret: getRootCType(tfunc.t)
						},
						pos: f.pos
					});
				default: Context.fatalError('Internal error: Expected function expression', f.pos);
			}
		}
	}

	static macro function runUserMain() {
		var mainClassPath = getMainFromHaxeArgs(Sys.args());
		if (mainClassPath == null) {
			return macro null;
		} else {
			return Context.parse('$mainClassPath.main()', Context.currentPos());
		}
	}

	static function isLibraryBuild() {
		return Context.defined('dll_link') || Context.defined('static_link');
	}

	static function getCNameMeta(meta: MetaAccess): Null<String> {
		var cNameMeta = meta.extract('HaxeCBridge.name')[0];
		return if (cNameMeta != null) {
			switch cNameMeta.params {
				case [{expr: EConst(CString(name))}]:
					safeIdent(name);
				default:
					Context.error('Incorrect usage, syntax is @${cNameMeta.name}(name: String)', cNameMeta.pos);
			}
		} else null;
	}

	static function generateHeader(ctx: CConverterContext, namespace: String) {
		ctx.requireHeader('stdbool.h', false); // we use bool for _stopHaxeThread()

		var includes = ctx.includes.copy();
		// sort includes, by <, " and alphabetically
		includes.sort((a, b) -> {
			var i = (a.quoted ? 1 : -1);
			var j = (b.quoted ? 1 : -1);
			return if (i == j) {
				a.path > b.path ? 1 : -1; 
			} else i - j;
		});
		return code('
			/**
			 * $namespace.h
			 * ${isLibraryBuild() ? 
			 	'Automatically generated by HaxeCBridge' :
				'! Warning, binary not generated as a library, make sure to add `-D dll_link` or `-D static_link` when compiling the haxe project !'
				}
			 */

			#ifndef HaxeCBridge_${namespace}_h
			#define HaxeCBridge_${namespace}_h

			')

			+ (if (includes.length > 0) includes.map(CPrinter.printInclude).join('\n') + '\n\n'; else '')
			+ (if (ctx.macros.length > 0) ctx.macros.join('\n') + '\n' else '')
			+ (if (ctx.typeDeclarations.length > 0) ctx.typeDeclarations.map(d -> CPrinter.printDeclaration(d, true)).join(';\n') + ';\n\n'; else '')
			+ (if (ctx.supportTypeDeclarations.length > 0) ctx.supportTypeDeclarations.map(d -> CPrinter.printDeclaration(d, true)).join(';\n') + ';\n'; else '')

			+ code('
			typedef void (* HaxeExceptionCallback) (const char* exceptionInfo);

			#ifdef __cplusplus
			extern "C" {
			#endif

				/**
				 * Initializes a haxe thread that executes the haxe main() function remains alive indefinitely until told to stop.
				 * 
				 * This must be first before calling haxe functions (otherwise those calls will hang waiting for a response from the haxe thread).
				 * 
				 * @param unhandledExceptionCallback a callback to execute if an unhandled exception occurs on the haxe thread. The haxe thread will continue processing events after an unhandled exception and you may want to stop it after receiving this callback. Use `NULL` for no callback
				 * @returns `NULL` if the thread initializes successfully or a null-terminated C string if an error occurs during initialization
				 */
				const char* ${namespace}_initializeHaxeThread(HaxeExceptionCallback unhandledExceptionCallback);

				/**
				 * Stops the haxe thread, blocking until the thread has completed. Once ended, it cannot be restarted (this is because static variable state will be retained from the last run).
				 *
				 * Other threads spawned from the haxe thread may still be running (you must arrange to stop these yourself for safe app shutdown).
				 *
				 * It can be safely called any number of times – if the haxe thread is not running this function will just return.
				 * 
				 * After executing no more calls to main-thread haxe functions can be made (as these will hang waiting for a response from the main thread).
				 * 
				 * Thread-safety: Can be called safely called on any thread. If called on the haxe thread it will trigger the thread to stop but it cannot then block until stopped.
				 *
				 * @param waitOnScheduledEvents If `true`, this function will wait for all events scheduled to execute in the future on the haxe thread to complete – this is the same behavior as running a normal hxcpp program. If `false`, immediate pending events will be finished and the thread stopped without executing events scheduled in the future
				 */
				void ${namespace}_stopHaxeThreadIfRunning(bool waitOnScheduledEvents);

		')
		+ indent(1, ctx.supportFunctionDeclarations.map(fn -> CPrinter.printDeclaration(fn, true)).join(';\n\n') + ';\n\n')
		+ indent(1, ctx.functionDeclarations.map(fn -> CPrinter.printDeclaration(fn, true)).join(';\n\n') + ';\n\n')

		+ code('
			#ifdef __cplusplus
			}
			#endif

			#endif /* HaxeCBridge_${namespace}_h */
		');
	}

	static function generateImplementation(ctx: CConverterContext, namespace: String) {
		return code('
			/**
			 * HaxeCBridge Function Binding Implementation
			 * Automatically generated by HaxeCBridge
			 */
			#include <hxcpp.h>
			#include <hx/Native.h>
			#include <hx/Thread.h>
			#include <hx/StdLibs.h>
			#include <hx/GC.h>
			#include <HaxeCBridge.h>
			#include <Retainer.h>
			#include <assert.h>
			#include <queue>
			#include <utility>
			#include <atomic>

			#include "../${namespace}.h"

		')
		+ headersRequiredForImplementation.map(CPrinter.printInclude).join('\n') + '\n'
		+ code('

			namespace HaxeCBridgeInternal {
				std::atomic<bool> threadStarted = { false };
				std::atomic<bool> threadRunning = { false };
				// once haxe statics are initialized we cannot clear them for a clean restart
				std::atomic<bool> staticsInitialized = { false };

				struct HaxeThreadData {
					HaxeExceptionCallback haxeExceptionCallback;
					const char* initExceptionInfo;
				};

				HxSemaphore threadInitSemaphore;
				HxSemaphore threadEndSemaphore;
				HxMutex threadManageMutex;
				Dynamic mainThreadRef;

				void defaultExceptionHandler(const char* info) {
					printf("Unhandled haxe exception: %s\\n", info);
				}

				typedef void (* MainThreadCallback)(void* data);
				HxMutex queueMutex;
				std::queue<std::pair<MainThreadCallback, void*>> queue;

				void runInMainThread(MainThreadCallback callback, void* data) {
					queueMutex.Lock();
					queue.push(std::make_pair(callback, data));
					queueMutex.Unlock();
					HaxeCBridge::wakeMainThread();
				}

				// called on the haxe main thread
				void processNativeCalls() {
					AutoLock lock(queueMutex);
					while(!queue.empty()) {
						std::pair<MainThreadCallback, void*> pair = queue.front();
						queue.pop();
						pair.first(pair.second);
					}
				}

				bool isHaxeMainThread() {
					hx::NativeAttach autoAttach;
					Dynamic currentInfo = __hxcpp_thread_current();
					return HaxeCBridgeInternal::mainThreadRef.mPtr == currentInfo.mPtr;
				}
			}

			THREAD_FUNC_TYPE haxeMainThreadFunc(void *data) {
				HX_TOP_OF_STACK
				HaxeCBridgeInternal::HaxeThreadData* threadData = (HaxeCBridgeInternal::HaxeThreadData*) data;
				HaxeCBridgeInternal::mainThreadRef = __hxcpp_thread_current();

				HaxeCBridgeInternal::threadRunning = true; // must come after mainThreadRef assignment

				threadData->initExceptionInfo = nullptr;

				// copy out callback
				HaxeExceptionCallback haxeExceptionCallback = threadData->haxeExceptionCallback;

				bool firstRun = !HaxeCBridgeInternal::staticsInitialized;

				// See hx::Init in StdLibs.cpp for reference
				if (!HaxeCBridgeInternal::staticsInitialized) try {
					::hx::Boot();
					__boot_all();
					HaxeCBridgeInternal::staticsInitialized = true;
				} catch(Dynamic initException) {
					// hxcpp init failure or uncaught haxe runtime exception
					threadData->initExceptionInfo = initException->toString().utf8_str();
				}

				if (HaxeCBridgeInternal::staticsInitialized) { // initialized without error
					// blocks running the event loop
					// keeps alive until manual stop is called
					HaxeCBridge::mainThreadInit();
					HaxeCBridgeInternal::threadInitSemaphore.Set();
					HaxeCBridge::mainThreadRun(HaxeCBridgeInternal::processNativeCalls, haxeExceptionCallback);
				} else {
					// failed to initialize statics; unlock init semaphore so _initializeHaxeThread can continue and report the exception 
					HaxeCBridgeInternal::threadInitSemaphore.Set();
				}

				HaxeCBridgeInternal::threadRunning = false;
				HaxeCBridgeInternal::threadEndSemaphore.Set();

				THREAD_FUNC_RET
			}

			HXCPP_EXTERN_CLASS_ATTRIBUTES
			const char* ${namespace}_initializeHaxeThread(HaxeExceptionCallback unhandledExceptionCallback) {
				HaxeCBridgeInternal::HaxeThreadData threadData = {
					.haxeExceptionCallback = unhandledExceptionCallback == nullptr ? HaxeCBridgeInternal::defaultExceptionHandler : unhandledExceptionCallback,
					.initExceptionInfo = nullptr,
				};

				{
					// mutex prevents two threads calling this function from being able to start two haxe threads
					AutoLock lock(HaxeCBridgeInternal::threadManageMutex);
					if (!HaxeCBridgeInternal::threadStarted) {
						// startup the haxe main thread
						HxCreateDetachedThread(haxeMainThreadFunc, &threadData);

						HaxeCBridgeInternal::threadStarted = true;

						// wait until the thread is initialized and ready
						HaxeCBridgeInternal::threadInitSemaphore.Wait();
					} else {
						threadData.initExceptionInfo = "haxe thread cannot be started twice";
					}
				}
				
				if (threadData.initExceptionInfo != nullptr) {
					${namespace}_stopHaxeThreadIfRunning(false);

					const int returnInfoMax = 1024;
					static char returnInfo[returnInfoMax] = ""; // statically allocated for return safety
					strncpy(returnInfo, threadData.initExceptionInfo, returnInfoMax);
					return returnInfo;
				} else {
					return nullptr;
				}
			}

			HXCPP_EXTERN_CLASS_ATTRIBUTES
			void ${namespace}_stopHaxeThreadIfRunning(bool waitOnScheduledEvents) {
				if (HaxeCBridgeInternal::isHaxeMainThread()) {
					// it is possible for stopHaxeThread to be called from within the haxe thread, while another thread is waiting on HaxeCBridgeInternal::threadEndSemaphore
					// so it is important the haxe thread does not wait on certain locks
					HaxeCBridge::endMainThread(waitOnScheduledEvents);
				} else {
					AutoLock lock(HaxeCBridgeInternal::threadManageMutex);
					if (HaxeCBridgeInternal::threadRunning) {
						struct Callback {
							static void run(void* data) {
								bool* b = (bool*) data;
								HaxeCBridge::endMainThread(*b);
							}
						};

						HaxeCBridgeInternal::runInMainThread(Callback::run, &waitOnScheduledEvents);

						{
							hx::NativeAttach autoAttach;
							__hxcpp_enter_gc_free_zone();
							HaxeCBridgeInternal::threadEndSemaphore.Wait();
							__hxcpp_exit_gc_free_zone();
						}
					}
				}
			}

			HXCPP_EXTERN_CLASS_ATTRIBUTES
			void ${namespace}_releaseHaxeObject(HaxeObject obj) {
				struct Callback {
					static void run(void* data) {
						HaxeCBridge::releaseHaxeObject(Retainer((hx::Object *)data, false));
					}
				};
				HaxeCBridgeInternal::runInMainThread(Callback::run, obj);
			}

		')
		+ ctx.functionDeclarations.map(d -> generateFunctionImplementation(namespace, d)).join('\n') + '\n'
		;
	}

	static function generateFunctionImplementation(namespace: String, d: CDeclaration) {
		var signature = switch d.kind {case Function(sig): sig; default: null;};
		var haxeFunction = functionInfo.get(signature.name);
		var hasReturnValue = !haxeFunction.rootCTypes.ret.match(Ident('void'));
		var externalThread = haxeFunction.field.meta.has('externalThread');

		// rename signature args to a1, a2, a3 etc, this is to avoid possible conflict with local function variables
		var signature: CFunctionSignature = {
			name: signature.name,
			args: signature.args.mapi((i, arg) -> {name: 'a$i', type: arg.type}),
			ret: signature.ret,
		}
		var d: CDeclaration = { kind: Function(signature) }

		// cast a C type to one which works with hxcpp
		inline function castC2Cpp(expr: String, rootCType: CType) {
			// type cast argument before passing to hxcpp
			return switch rootCType {
				case Enum(_): expr; // enum to int works with implicit cast
				case Ident('HaxeObject'): 'Retainer((hx::Object *)$expr, false)';
				case Ident(_), FunctionPointer(_), InlineStruct(_), Pointer(_): expr; // hxcpp auto casting works
			}
		}

		inline function castCpp2C(expr: String, cType: CType, rootCType: CType) {
			// cast hxcpp type to c
			return switch rootCType {
				case Enum(_): 'static_cast<${CPrinter.printType(cType)}>($expr)'; // need explicit cast for int -> enum
				case Ident('HaxeObject'): '(HaxeObject)($expr.mPtr)';
				case Ident(_), FunctionPointer(_), InlineStruct(_), Pointer(_): expr; // hxcpp auto casting works
			}
		}

		inline function callWithArgs(argNames: Array<String>) {
			var callExpr = '${haxeFunction.hxcppName}(${
				argNames.mapi((i, arg) -> {
					castC2Cpp(arg, haxeFunction.rootCTypes.args[i]);
				}).join(', ')
			})';
			return if (hasReturnValue) {
				castCpp2C(callExpr, signature.ret, haxeFunction.rootCTypes.ret);
			} else {
				callExpr;
			}
		}

		if (externalThread) {
			// straight call through
			return (
				code('
					HXCPP_EXTERN_CLASS_ATTRIBUTES
					${CPrinter.printDeclaration(d, false)} {
						hx::NativeAttach autoAttach;
						return ${callWithArgs(signature.args.map(a->a.name))};
					}
				')
			);
		} else {
			// main thread synchronization implementation
			var fnDataTypeName = 'Data';
			var fnDataName = 'data';
			var fnDataStruct: CStruct = {
				fields: [
					{
						name: 'args',
						type: InlineStruct({fields: signature.args})
					},
					{
						name: 'lock',
						type: Ident('HxSemaphore')
					}
				].concat(
					hasReturnValue ? [{
						name: 'ret',
						type: signature.ret
					}] : []
				)
			};

			var fnDataDeclaration: CDeclaration = { kind: Struct(fnDataTypeName, fnDataStruct) }

			return (
				code('
					HXCPP_EXTERN_CLASS_ATTRIBUTES
				')
				+ CPrinter.printDeclaration(d, false) + ' {\n'
				+ indent(1,
					code('
						if (HaxeCBridgeInternal::isHaxeMainThread()) {
							return ${callWithArgs(signature.args.map(a->a.name))};
						}
					')
					+ CPrinter.printDeclaration(fnDataDeclaration) + ';\n'
					+ code('
						struct Callback {
							static void run(void* p) {
								// executed within the haxe main thread
								$fnDataTypeName* $fnDataName = ($fnDataTypeName*) p;
								try {
									${hasReturnValue ?
										'$fnDataName->ret = ${callWithArgs(signature.args.map(a->'$fnDataName->args.${a.name}'))};' :
										'${callWithArgs(signature.args.map(a->'$fnDataName->args.${a.name}'))};'
									}
									$fnDataName->lock.Set();
								} catch(Dynamic runtimeException) {
									$fnDataName->lock.Set();
									throw runtimeException;
								}
							}
						};

						#ifdef HXCPP_DEBUG
						assert(HaxeCBridgeInternal::threadRunning && "haxe thread not running, use ${namespace}_initializeHaxeThread() to activate the haxe thread");
						#endif

						$fnDataTypeName $fnDataName = { {${signature.args.map(a->a.name).join(', ')}} };

						// queue a callback to execute ${haxeFunction.field.name}() on the main thread and wait until execution completes
						HaxeCBridgeInternal::runInMainThread(Callback::run, &$fnDataName);
						$fnDataName.lock.Wait();
					')
					+ if (hasReturnValue) code('
						return $fnDataName.ret;
					') else ''
				)
				+ code('
					}
				')
			);
		}
	}

	/**
		We determine a project name to be the `--main` startup class or the first specified class-path

		The user can override this with `-D HaxeCBridge.name=ExampleName`

		This isn't rigorously defined but hopefully will produced nicely namespaced and unsurprising function names
	**/
	static function getLibNameFromHaxeArgs(): Null<String> {
		var overrideName = Context.definedValue('HaxeCBridge.name');
		if (overrideName != null && overrideName != '') {
			return safeIdent(overrideName);
		}

		var args = Sys.args();
		
		var mainClassPath = getMainFromHaxeArgs(args);
		if (mainClassPath != null) {
			return safeIdent(mainClassPath);
		}

		// default to HaxeLibrary
		return 'HaxeCBridge';
	}

	static function getMainFromHaxeArgs(args: Array<String>): Null<String> {
		for (i in 0...args.length) {
			var arg = args[i];
			switch arg {
				case '-m', '-main', '--main':
					var classPath = args[i + 1];
					return classPath;
				default:
			}
		}
		return null;
	}

	static function safeIdent(str: String) {
		// replace non a-z0-9_ with _
		str = ~/[^\w]/gi.replace(str, '_');
		// replace leading number with _
		str = ~/^[^a-z_]/i.replace(str, '_');
		// replace empty string with _
		str = str == '' ? '_' : str;
		return str;
	}

}

enum CModifier {
	Const;
}

enum CType {
	Ident(name: String, ?modifiers: Array<CModifier>);
	Pointer(t: CType, ?modifiers: Array<CModifier>);
	FunctionPointer(name: String, argTypes: Array<CType>, ret: CType, ?modifiers: Array<CModifier>);
	InlineStruct(struct: CStruct);
	Enum(name: String);
}

// not exactly specification C but good enough for this purpose
enum CDeclarationKind {
	Typedef(type: CType, declarators: Array<String>);
	Enum(name: String, fields: Array<{name: String, ?value: Int}>);
	Function(fun: CFunctionSignature);
	Struct(name: String, struct: CStruct);
	Variable(name: String, type: CType);
}

enum CCustomMeta {
	CppFunction(str: String);
}

typedef CDeclaration = {
	kind: CDeclarationKind,
	?doc: String,
}

typedef CStruct = {
	fields: Array<{name: String, type: CType}>
}

typedef CFunctionSignature = {
	name: String,
	args: Array<{name: String, type: CType}>,
	ret: CType
}

typedef CInclude = {
	path: String,
	quoted: Bool,
}

typedef CMacro = {
	directive: String,
	name: String,
	content: String,
}

class CPrinter {

	public static function printInclude(inc: CInclude) {
		return '#include ${inc.quoted ? '"' : '<'}${inc.path}${inc.quoted ? '"' : '>'}';
	}

	public static function printMacro(cMacro: CMacro) {
		var escapedContent = cMacro.content.replace('\n', '\n\\');
		return '#${cMacro.directive} ${cMacro.name} ${escapedContent}';
	}

	public static function printType(cType: CType): String {
		return switch cType {
			case Ident(name, modifiers):
				(hasModifiers(modifiers) ? (printModifiers(modifiers) + ' ') : '') + name;
			case Pointer(t, modifiers):
				printType(t) + '*' + (hasModifiers(modifiers) ? (' ' + printModifiers(modifiers)) : '');
			case FunctionPointer(name, argTypes, ret):
				'${printType(ret)} (* $name) (${argTypes.length > 0 ? argTypes.map(printType).join(', ') : 'void'})';
			case InlineStruct(struct):
				'struct {${printFields(struct.fields, false)}}';
			case Enum(name):
				'enum $name';
		}
	}

	public static function printDeclaration(cDeclaration: CDeclaration, docComment: Bool = true) {
		return
			(cDeclaration.doc != null && docComment ? (printDoc(cDeclaration.doc) + '\n') : '')
			+ switch cDeclaration.kind {
				case Typedef(type, declarators):
					'typedef ${printType(type)}' + (declarators.length > 0 ? ' ${declarators.join(', ')}' :'');
				case Enum(name, fields):
					'enum $name {\n'
					+ fields.map(f -> '\t' + f.name + (f.value != null ? ' = ${f.value}' : '')).join(',\n') + '\n'
					+ '}';
				case Struct(name, {fields: fields}):
					'struct $name {\n'
					+ printFields(fields, true)
					+ '}';
				case Function(sig):
					printFunctionSignature(sig);
				case Variable(name, type):
					'${printType} $name';
		}
	}

	public static function printFields(fields: Array<{name: String, type: CType}>, newlines: Bool) {
		var sep = (newlines?'\n':' ');
		return fields.map(f -> '${newlines?'\t':''}${printField(f)}').join(sep) + (newlines?'\n':'');
	}

	public static function printField(f: {name: String, type: CType}) {
		return '${printType(f.type)} ${f.name};';
	}

	public static function printFunctionSignature(signature: CFunctionSignature) {
		var name = signature.name;
		var args = signature.args;
		var ret = signature.ret;
		return '${printType(ret)} $name(${args.map(arg -> '${printType(arg.type)} ${arg.name}').join(', ')})';
	}

	public static function printDoc(doc: String) {
		return '/**\n${doc.split('\n').map(l -> ' * ' + l).join('\n')}\n */';
	}

	static function hasModifiers(modifiers: Null<Array<CModifier>>)
		return modifiers != null && modifiers.length > 0;

	public static function printModifiers(modifiers: Null<Array<CModifier>>) {
		return if (hasModifiers(modifiers)) modifiers.map(printModifier).join('\n');
		else '';
	}

	public static function printModifier(modifier: CModifier) {
		return switch modifier {
			case Const: 'const';
		}
	}

}

class CConverterContext {

	public final includes = new Array<CInclude>();
	public final macros = new Array<String>();

	public final supportTypeDeclarations = new Array<CDeclaration>();
	final supportDeclaredTypeIdentifiers = new Map<String, Bool>();

	public final supportFunctionDeclarations = new Array<CDeclaration>();
	final supportDeclaredFunctionIdentifiers = new Map<String, Position>();

	public final typeDeclarations = new Array<CDeclaration>();
	final declaredTypeIdentifiers = new Map<String, Bool>();
	
	public final functionDeclarations = new Array<CDeclaration>();
	final declaredFunctionIdentifiers = new Map<String, Position>();
	
	final declarationPrefix: String;
	final generateTypedef: Bool;
	final generateTypedefForFunctions: Bool;
	final generateTypedefWithTypeParameters: Bool;
	final generateEnums: Bool;

	/**
		namespace is used to prefix types
	**/
	public function new(options: {
		?declarationPrefix: String,
		?generateTypedef: Bool,
		?generateTypedefForFunctions: Bool,
		/** type parameter name is appended to the typedef ident, this makes for long type names so it's disabled by default **/
		?generateTypedefWithTypeParameters: Bool,
		?generateEnums: Bool,
	} = null) {
		this.declarationPrefix = (options != null && options.declarationPrefix != null) ? options.declarationPrefix : '';
		this.generateTypedef = (options != null && options.generateTypedef != null) ? options.generateTypedef : true;
		this.generateTypedefForFunctions = (options != null && options.generateTypedefForFunctions != null) ? options.generateTypedefForFunctions : true;
		this.generateTypedefWithTypeParameters = (options != null && options.generateTypedefWithTypeParameters != null) ? options.generateTypedefWithTypeParameters : false;
		this.generateEnums = (options != null && options.generateEnums != null) ? options.generateEnums : true;
	}

	public function addFunctionDeclaration(name: String, fun: Function, doc: Null<String>, pos: Position) {
		functionDeclarations.push({
			doc: doc,
			kind: Function({
				name: name,
				args: fun.args.map(arg -> {
					name: cKeywords.has(arg.name) ? (arg.name + '_') : arg.name,
					type: convertComplexType(arg.type, true, pos)
				}),
				ret: convertComplexType(fun.ret, true, pos)
			})
		});
		declareFunctionIdentifier(name, pos);
	}

	public function addTypedFunctionDeclaration(name: String, tfunc: TFunc, doc: Null<String>, pos: Position) {
		functionDeclarations.push({
			doc: doc,
			kind: Function({
				name: name,
				args: tfunc.args.map(arg -> {
					name: cKeywords.has(arg.v.name) ? (arg.v.name + '_') : arg.v.name,
					type: convertType(arg.v.t, true, false, pos)
				}),
				ret: convertType(tfunc.t, true, false, pos)
			})
		});
		declareFunctionIdentifier(name, pos);
	}

	function declareFunctionIdentifier(name: String, pos: Position) {
		var existingDecl = declaredFunctionIdentifiers.get(name);
		if (existingDecl == null) {
			declaredFunctionIdentifiers.set(name, pos);
		} else {
			inline function locString(p: Position) {
				var l = PositionTools.toLocation(p);
				return '${l.file}:${l.range.start.line}';
			}
			Context.fatalError('HaxeCBridge: function "$name" (${locString(pos)}) generates the same C name as another function (${locString(existingDecl)})', pos);
		}
	}

	public function convertComplexType(ct: ComplexType, allowNonTrivial: Bool, pos: Position) {
		return convertType(Context.resolveType(ct, pos), allowNonTrivial, false, pos);
	}

	public function convertType(type: Type, allowNonTrivial: Bool, allowBareFnTypes: Bool, pos: Position): CType {
		var hasCoreTypeIndication = {
			var baseType = asBaseType(type);
			if (baseType != null) {
				var t = baseType.t;
				// externs in the cpp package are expected to be key-types
				t.isExtern && (t.pack[0] == 'cpp') ||
				t.meta.has(":coreType") ||
				// hxcpp doesn't mark its types as :coreType but uses :semantics and :noPackageRestrict sometimes
				t.meta.has(":semantics") ||
				t.meta.has(":noPackageRestrict");
			} else false;
		}

		if (hasCoreTypeIndication) {
			return convertKeyType(type, allowNonTrivial, allowBareFnTypes, pos);
		}
		
		return switch type {
			case TInst(_.get() => t, _):
				var keyCType = tryConvertKeyType(type, allowNonTrivial, allowBareFnTypes, pos);
				if (keyCType != null) {
					keyCType;
				} else if (t.isExtern) {
					// we can expose extern types (assumes they're compatible with C)
					var ident = {
						var nativeMeta = t.meta.extract(':native')[0];
						var nativeMetaValue = switch nativeMeta {
							case null: null;
							case {params: [{expr: EConst(CString(value))}]}: value;
							default: null;
						}
						nativeMetaValue != null ? nativeMetaValue : t.name;
					}
					// if the extern has @:include metas, copy the referenced header files so we can #include them locally
					var includes = t.meta.extract(':include');
					for (include in includes) {
						switch include.params {
							case null:
							case [{expr: EConst(CString(includePath))}]:
								// copy the referenced include into the compiler output directory and require this header
								var filename = Path.withoutDirectory(includePath);
								var absoluteIncludePath = Path.join([getAbsolutePosDirectory(t.pos), includePath]);
								var targetDirectory = Compiler.getOutput();
								var targetFilePath = Path.join([targetDirectory, filename]);

								if (!FileSystem.exists(targetDirectory)) {
									// creates intermediate directories if required
									FileSystem.createDirectory(targetDirectory);
								}

								File.copy(absoluteIncludePath, targetFilePath);
								requireHeader(filename, true);
							default:
						}
					}
					Ident(ident);
				} else {
					Context.error('Could not convert type "${TypeTools.toString(type)}" to C representation. To safely pass arbitrary haxe objects to C you can wrap them opaquely in HaxeCBridge.Retainer<T>', pos);
				}

			case TFun(args, ret):
				if (allowBareFnTypes) {
					getFunctionCType(args, ret, pos);
				} else {
					Context.error("Callbacks must be wrapped in cpp.Callable<T> when exposing to C", pos);
				}

			case TAnonymous(a):
				Context.error("Haxe structures are not supported when exposing to C, try using an extern for a C struct instead (you may also wrapping the object opaquely in HaxeCBridge.Retainer<T>)", pos);

			case TAbstract(_.get() => t, _):
				var keyCType = tryConvertKeyType(type, allowNonTrivial, allowBareFnTypes, pos);
				if (keyCType != null) {
					keyCType;
				} else {
					var isPublicEnumAbstract = t.meta.has(':enum') && !t.isPrivate;
					var isIntEnumAbstract = if (isPublicEnumAbstract) {
						var underlyingRootType = TypeTools.followWithAbstracts(t.type, false);
						Context.unify(underlyingRootType, Context.resolveType(macro :Int, Context.currentPos()));
					} else false;
					if (isIntEnumAbstract && generateEnums) {
						// c-enums can be converted to ints
						getEnumCType(type, allowNonTrivial, pos);
					} else {
						// follow once abstract's underling type
						convertType(TypeTools.followWithAbstracts(type, true), allowNonTrivial, allowBareFnTypes, pos);
					}
				}
			
			case TType(_.get() => t, params):
				var keyCType = tryConvertKeyType(type, allowNonTrivial, allowBareFnTypes, pos);
				if (keyCType != null) {
					keyCType;
				} else {

					var useDeclaration =
						generateTypedef &&
						(params.length > 0 ? generateTypedefWithTypeParameters : true) &&
						!t.isPrivate;

					if (useDeclaration) {
						getTypeAliasCType(type, allowNonTrivial, allowBareFnTypes, pos);
					} else {
						// follow type alias (with type parameter)
						convertType(TypeTools.follow(type, true), allowNonTrivial, allowBareFnTypes, pos);
					}
				}

			case TLazy(f):
				convertType(f(), allowNonTrivial, allowBareFnTypes, pos);

			case TDynamic(t):
				Context.error("Any and Dynamic types are not supported when exposing to C", pos);
			
			case TMono(t):
				Context.error("Explicit type is required when exposing to C", pos);

			case TEnum(t, params):
				Context.error("Exposing enum types to C is not supported, try using an enum abstract over Int", pos);
		}
	}

	/**
		Convert a key type and expect a result (or fail)
		A key type is like a core type (and includes :coreType types) but also includes hxcpp's own special types that don't have the :coreType annotation
	**/
	function convertKeyType(type: Type, allowNonTrivial:Bool, allowBareFnTypes: Bool, pos: Position): CType {
		var keyCType = tryConvertKeyType(type, allowNonTrivial, allowBareFnTypes, pos);
		return if (keyCType == null) {
			var p = new Printer();
			Context.warning('No corresponding C type found for "${TypeTools.toString(type)}" (using void* instead)', pos);
			Pointer(Ident('void'));
		} else keyCType;
	}

	/**
		Return CType if Type was a key type and null otherwise
	**/
	function tryConvertKeyType(type: Type, allowNonTrivial:Bool, allowBareFnTypes: Bool, pos: Position): Null<CType> {
		var base = asBaseType(type);
		return if (base != null) {
			switch base {

				/**
					See `cpp_type_of` in gencpp.ml
					https://github.com/HaxeFoundation/haxe/blob/65bb88834cea059035a73db48e79c7a5c5817ee8/src/generators/gencpp.ml#L1743
				**/

				case {t: {pack: [], name: "Null"}}:
					Context.error("Null<T> is not supported for C export", pos);
				case {t: {pack: [], name: "Array"}}:
					Context.error("Array<T> is not supported for C export, try using cpp.Pointer<T> instead", pos);

				case {t: {pack: [], name: 'Void' | 'void'}}: Ident('void');
				case {t: {pack: [], name: "Bool"}}: requireHeader('stdbool.h'); Ident("bool");
				case {t: {pack: [], name: "Float"}}: Ident("double");
				case {t: {pack: [], name: "Int"}}: Ident("int");
				case {t: {pack: [], name: "Single"}}: Ident("float");

				case {t: {pack: ["cpp"], name: "Void"}}: Ident('void');
				case {t: {pack: ["cpp"], name: "SizeT"}}: requireHeader('stddef.h'); Ident("size_t");
				case {t: {pack: ["cpp"], name: "Char"}}: Ident("char");
				case {t: {pack: ["cpp"], name: "Float32"}}: Ident("float");
				case {t: {pack: ["cpp"], name: "Float64"}}: Ident("double");
				case {t: {pack: ["cpp"], name: "Int8"}}: Ident("signed char");
				case {t: {pack: ["cpp"], name: "Int16"}}: Ident("short");
				case {t: {pack: ["cpp"], name: "Int32"}}: Ident("int");
				case {t: {pack: ["cpp"], name: "Int64"}}: requireHeader('stdint.h'); Ident("int64_t");
				case {t: {pack: ["cpp"], name: "UInt8"}}: Ident("unsigned char");
				case {t: {pack: ["cpp"], name: "UInt16"}}: Ident("unsigned short");
				case {t: {pack: ["cpp"], name: "UInt32"}}: Ident("unsigned int");
				case {t: {pack: ["cpp"], name: "UInt64"}}: requireHeader('stdint.h'); Ident("uint64_t");

				case {t: {pack: ["cpp"], name: "Star" | "RawPointer"}, params: [tp]}: Pointer(convertType(tp, false, allowBareFnTypes, pos));
				case {t: {pack: ["cpp"], name: "ConstStar" | "RawConstPointer" }, params: [tp]}: Pointer(setModifier(convertType(tp, false, allowBareFnTypes, pos), Const));

				// non-trivial types
				// hxcpp will convert these automatically if primary type but not if secondary (like as argument type or pointer type)
				case {t: {pack: [], name: "String"}}:
					if (allowNonTrivial) {
						Pointer(Ident("char", [Const]));
					} else {
						Context.error('String is not supported as secondary type for C export, use cpp.ConstCharStar instead', pos);
					}

				case {t: {pack: ["cpp"], name: "Pointer"}, params: [tp]}:
					if (allowNonTrivial) {
						Pointer(convertType(tp, false, allowBareFnTypes, pos));
					} else {
						Context.error('cpp.Pointer is not supported as secondary type for C export, use cpp.Star or cpp.RawPointer instead', pos);
					}
				case {t: {pack: ["cpp"], name: "ConstPointer" }, params: [tp]}:
					if (allowNonTrivial) {
						Pointer(setModifier(convertType(tp, false, allowBareFnTypes, pos), Const));
					} else {
						Context.error('cpp.ConstPointer is not supported as secondary type for C export, use cpp.ConstStar or cpp.RawRawPointer instead', pos);
					}
				case {t: {pack: ["cpp"], name: "Callable" | "CallableData"}, params: [tp]}:
					if (allowNonTrivial) {
						convertType(tp, false, true, pos);
					} else {
						Context.error('${base.t.pack.concat([base.t.name]).join('.')} is not supported as secondary type for C export', pos);
					}
				case {t: {pack: ["cpp"], name: "Function"}, params: [tp, abi]}:
					if (allowNonTrivial) {
						convertType(tp, false, true, pos);
					} else {
						Context.error('${base.t.pack.concat([base.t.name]).join('.')} is not supported as secondary type for C export', pos);
					}

				case {t: {pack: ["cpp"], name: name =
					"Reference" |
					"AutoCast" |
					"VarArg" |
					"FastIterator"
				}}:
					Context.error('cpp.$name is not supported for C export', pos);

				// special type that ensures a GC reference is retained so it can be safely handled in C
				// resolves to void*
				case {t: {pack: [], name: 'Retainer', params: [tp]} }:
					getHaxeObjectCType(tp.t);
					
				default:
					// case {pack: [], name: "EnumValue"}: Ident
					// case {pack: [], name: "Class"}: Ident
					// case {pack: [], name: "Enum"}: Ident
					// case {pack: ["cpp"], name: "Object"}: Ident;
					// (* Things with type parameters hxcpp knows about ... *)
					// | (["cpp"],"Struct"), [param] ->
					// 						TCppStruct(cpp_type_of stack ctx param)
					null;
			}
		} else null;
	}

	function asBaseType(type: Type): Null<{t: BaseType, params: Array<Type>}> {
		return switch type {
			case TMono(t): null;
			case TEnum(t, params): {t: t.get(), params: params};
			case TInst(t, params): {t: t.get(), params: params};
			case TType(t, params): {t: t.get(), params: params};
			case TAbstract(t, params): {t: t.get(), params: params};
			case TFun(args, ret): null;
			case TAnonymous(a): null;
			case TDynamic(t): null;
			case TLazy(f): asBaseType(f());
		}
	}

	function setModifier(cType: CType, modifier: CModifier): CType {
		inline function _setModifier(modifiers: Null<Array<CModifier>>) {
			return if (modifiers == null) {
				[modifier];
			} else if (!modifiers.has(modifier)) {
				modifiers.push(modifier);
				modifiers;
			} else modifiers;
		}
		return switch cType {
			case Ident(name, modifiers): Ident(name, _setModifier(modifiers));
			case Pointer(type, modifiers): Pointer(type, _setModifier(modifiers));
			case FunctionPointer(name, argTypes, ret, modifiers): FunctionPointer(name, argTypes, ret, _setModifier(modifiers));
			case InlineStruct(struct): cType;
			case Enum(name): cType; 
		}
	}

	public function requireHeader(path: String, quoted: Bool = false) {
		if (!includes.exists(f -> f.path == path && f.quoted == quoted)) {
			includes.push({
				path: path,
				quoted: quoted
			});
		}
	}

	function getEnumCType(type: Type, allowNonTrivial: Bool, pos: Position): CType {
		var ident = declarationPrefix + '_' + typeDeclarationIdent(type);

		// `enum ident` is considered non-trivial
		if (!allowNonTrivial) {
			Context.error('Enums are not allowed as secondary types, consider using Int instead', pos);
		}

		if (!declaredTypeIdentifiers.exists(ident)) {
			
			switch type {
				case TAbstract(_.get() => a, params) if(a.meta.has(':enum')):
					var enumFields = a.impl.get().statics.get()
						.filter(field -> field.meta.has(':enum') && field.meta.has(':value'))
						.map(field -> {
							name: field.name,
							value: getValue(field.meta.extract(':value')[0].params[0])
						});

					typeDeclarations.push({kind: Enum(ident, enumFields)});

				default: Context.fatalError('Internal error: Expected enum abstract but got $type', pos);
			}
			declaredTypeIdentifiers.set(ident, true);
			
		}
		return Enum(ident);
	}

	function getTypeAliasCType(type: Type, allowNonTrivial: Bool, allowBareFnTypes: Bool, pos: Position): CType {
		var ident = declarationPrefix + '_' + typeDeclarationIdent(type);

		// order of typedef typeDeclarations should be dependency correct because required typedefs are added before this typedef is added
		// we call this outside the exists() branch below to make sure `allowNonTrivial` and `allowBareFnTypes` errors will be caught
		// otherwise the following may allow a non-trivial type as a secondary:
		// func(a: NonTrivialAlias, b: Star<NonTrivialAlias>) because `NonTrivialAlias` is first created when converting `a` and then referenced without checks for `b`
		var aliasedType = convertType(TypeTools.follow(type, true), allowNonTrivial, allowBareFnTypes, pos);

		if (!declaredTypeIdentifiers.exists(ident)) {
			
			typeDeclarations.push({kind: Typedef(aliasedType, [ident])});
			declaredTypeIdentifiers.set(ident, true);
			
		}
		return Ident(ident);
	}

	function getFunctionCType(args: Array<{name: String, opt: Bool, t: Type}>, ret: Type, pos: Position): CType {
		// optional type parameters are not supported and become non-optional

		var ident = 'function_' + args.map(arg -> typeDeclarationIdent(arg.t)).concat([typeDeclarationIdent(ret)]).join('_');
		var funcPointer: CType = FunctionPointer(
			ident,
			args.map(arg -> convertType(arg.t, false, false, pos)),
			convertType(ret, false, false, pos)
		);

		if (generateTypedefForFunctions) {
			if (!declaredTypeIdentifiers.exists(ident)) {
				typeDeclarations.push({kind: Typedef(funcPointer, []) });
				declaredTypeIdentifiers.set(ident, true);			
			}
			return Ident(ident);
		} else {
			return funcPointer;
		}
	}

	function getHaxeObjectCType(t: Type): CType {
		// in the future we could specialize based on t (i.e. generating another typedef name like HaxeObject_SomeType)
		var typeIdent = 'HaxeObject';
		var functionIdent = '${declarationPrefix}_releaseHaxeObject';

		if (!supportDeclaredTypeIdentifiers.exists(typeIdent)) {
			supportTypeDeclarations.push({
				kind: Typedef(Pointer(Ident('void')), [typeIdent])
			});
			supportDeclaredTypeIdentifiers.set(typeIdent, true);
		}
		if (!supportDeclaredFunctionIdentifiers.exists(functionIdent)) {
			supportFunctionDeclarations.push({
				doc: code('
					Informs the garbage collector that object is no longer needed by the C code.

					If the object has no remaining reference the garbage collector will free the associated memory (which can happen at any time in the future). It does not free the memory immediately.

					Thread-safety: can be called on any thread.
					
					@param haxeObject a handle to an arbitrary haxe object returned from a haxe function'),
				kind: Function({
					name: functionIdent,
					args: [{name: 'haxeObject', type: Ident(typeIdent)}],
					ret: Ident('void')
				})
			});
			supportDeclaredFunctionIdentifiers.set(functionIdent, Context.currentPos());
		}
		return Ident(typeIdent);
	}

	// generate a type identifier for declaring a haxe type in C
	function typeDeclarationIdent(type: Type) {
		return safeIdent(TypeTools.toString(type));
	}

	static function safeIdent(str: String) {
		// replace non a-z0-9_ with _
		str = ~/[^\w]/gi.replace(str, '_');
		// replace leading number with _
		str = ~/^[^a-z_]/i.replace(str, '_');
		// replace empty string with _
		str = str == '' ? '_' : str;
		if (cKeywords.has(str)) {
			str = str + '_';
		}
		return str;
	}

	/**
		Return the directory of the Context's current position

		For a @:build macro, this is the directory of the haxe file it's added to
	**/
	static function getAbsolutePosDirectory(pos: haxe.macro.Expr.Position) {
		var classPosInfo = Context.getPosInfos(pos);
		var classFilePath = Path.isAbsolute(classPosInfo.file) ? classPosInfo.file : Path.join([Sys.getCwd(), classPosInfo.file]);
		return Path.directory(classFilePath);
	}

	/**
		Extends ExprTools.getValue to skip through ECast
	**/
	static function getValue(expr: Expr) {
		return switch expr.expr {
			case ECast(e, t): getValue(e);
			default: ExprTools.getValue(expr);
		}
	}

	static public final cKeywords: Array<String> = [
		"auto", "double", "int", "struct", "break", "else", "long", "switch", "case", "enum", "register", "typedef", "char", "extern", "return", "union", "const", "float", "short", "unsigned", "continue", "for", "signed", "void", "default", "goto", "sizeof", "volatile", "do", "if", "static", "while",
		"size_t", "int64_t", "uint64_t",
		// HaxeCBridge types
		"HaxeObject", "HaxeExceptionCallback",
	];

}

class CodeTools {

	static public function code(str: String) {
		str = ~/^[ \t]*\n/.replace(str, '');
		str = ~/\n[ \t]*$/.replace(str, '\n');
		return removeIndentation(str);
	}

	/**
		Remove common indentation from lines in a string
	**/
	static public function removeIndentation(str: String) {
		// find common indentation across all lines
		var lines = str.split('\n');
		var commonTabsCount: Null<Int> = null;
		var commonSpaceCount: Null<Int> = null;
		var spacePrefixPattern = ~/^([ \t]*)[^\s]/;
		for (line in lines) {
			if (spacePrefixPattern.match(line)) {
				var space = spacePrefixPattern.matched(1);
				var tabsCount = 0;
				var spaceCount = 0;
				for (i in 0...space.length) {
					if (space.charAt(i) == '\t') tabsCount++;
					if (space.charAt(i) == ' ') spaceCount++;
				}
				commonTabsCount = commonTabsCount != null ? Std.int(Math.min(commonTabsCount, tabsCount)) : tabsCount;
				commonSpaceCount = commonSpaceCount != null ? Std.int(Math.min(commonSpaceCount, spaceCount)) : spaceCount;
			}
		}

		var spaceCharCount: Int = commonTabsCount + commonSpaceCount;

		// remove commonSpacePrefix from lines
		return spaceCharCount > 0 ? lines.map(
			line -> spacePrefixPattern.match(line) ? line.substr(spaceCharCount) : line
		).join('\n') : str;
	}

	static public function indent(level: Int, str: String) {
		var t = [for (i in 0...level) '\t'].join('');
		str = str.split('\n').map(l -> {
			if (~/^[ \t]*$/.match(l)) l else t + l;
		}).join('\n');
		return str;
	}

}

	#end // (display || display_details || target.name != cpp)

#else

// runtime HaxeCBridge

import cpp.Callable;
import cpp.Int64;
import cpp.Star;
import haxe.EntryPoint;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

@:nativeGen
@:keep
@:noCompletion
class HaxeCBridge {

	#if (haxe_ver >= 4.2)
	@:noCompletion
	static public function mainThreadInit() @:privateAccess {
		// replaces __hxcpp_main() in __main__.cpp
		Thread.initEventLoop();

		Internal.mainThread = Thread.current();
		Internal.mainThreadWaitLock = Thread.current().events.waitLock;

		EntryPoint.init();
	}

	@:noCompletion
	static public function mainThreadRun(processNativeCalls: cpp.Callable<Void -> Void>, onUnhandledException: cpp.Callable<cpp.ConstCharStar -> Void>) @:privateAccess {
		try {
			runUserMain();
		} catch (e: Any) {
			onUnhandledException(Std.string(e));
		}

		// run always-alive event loop
		var eventLoop:CustomEventLoop = Thread.current().events;

		var events = [];
		while(Internal.mainThreadLoopActive) {
			try {
				// execute any queued native callbacks
				processNativeCalls();

				// adapted from EventLoop.loop()
				var eventTickInfo = eventLoop.customProgress(Sys.time(), events);
				switch (eventTickInfo.nextEventAt) {
					case -2: // continue to next loop
					case -1:
						if (Internal.mainThreadEndIfNoPending && !eventTickInfo.anyTime) {
							// no events scheduled in the future and not waiting on any promises
							break;
						}
						Internal.mainThreadWaitLock.wait();
					case time:
						var timeout = time - Sys.time();
						Internal.mainThreadWaitLock.wait(Math.max(0, timeout));
				}
			} catch (e: Any) {
				onUnhandledException(Std.string(e));
			}
		}

		// run a major collection when the thread ends
		cpp.vm.Gc.run(true);
	}
	#else
	@:noCompletion
	static public function mainThreadInit() @:privateAccess {
		Internal.mainThread = Thread.current();
		Internal.mainThreadWaitLock = EntryPoint.sleepLock;
	}

	@:noCompletion
	static public function mainThreadRun(processNativeCalls: cpp.Callable<Void -> Void>, onUnhandledException: cpp.Callable<cpp.ConstCharStar -> Void>) @:privateAccess {
		try {
			runUserMain();
		} catch (e: Any) {
			onUnhandledException(Std.string(e));
		}

		while (Internal.mainThreadLoopActive) {
			try {
				// execute any queued native callbacks
				processNativeCalls();

				// adapted from EntryPoint.run()
				var nextTick = EntryPoint.processEvents();
				if (nextTick < 0) {
					if (Internal.mainThreadEndIfNoPending) {
						// no events scheduled in the future and not waiting on any promises
						break;
					}
					Internal.mainThreadWaitLock.wait();
				} else if (nextTick > 0) {
					Internal.mainThreadWaitLock.wait(nextTick); // wait until nextTick or wakeup() call
				}
			} catch (e: Any) {
				onUnhandledException(Std.string(e));
			}
		}

		// run a major collection when the thread ends
		cpp.vm.Gc.run(true);
	}
	#end

	static public function releaseHaxeObject(haxeObject: Retainer<Any>) {
		haxeObject.release();
	}

	@:noCompletion
	static public inline function isMainThread(): Bool {
		return inline Thread.current() == Internal.mainThread;
	}
	
	/** not thread-safe, must be called in the haxe main thread **/
	@:noCompletion
	static public function endMainThread(waitOnScheduledEvents: Bool) {
		Internal.mainThreadEndIfNoPending = true;
		Internal.mainThreadLoopActive = Internal.mainThreadLoopActive && waitOnScheduledEvents;
		inline wakeMainThread();
	}

	/** called from _unattached_ external thread, must not allocate in hxcpp **/
	@:noDebug
	@:noCompletion
	static public function wakeMainThread() {
		inline Internal.mainThreadWaitLock.release();
	}

	@:noCompletion
	static macro function runUserMain() { /* implementation provided above in macro version of HaxeCBridge */ }

}

private class Internal {
	public static var mainThread: Thread;
	public static var mainThreadWaitLock: Lock;
	public static var mainThreadLoopActive: Bool = true;
	public static var mainThreadEndIfNoPending: Bool = false;
}

/**
	Ensures a reference is retained to a given haxe object to prevent collection by the GC until release() is called.
**/
@:nullSafety
class Retainer<T> {

	static var retainedCount(default, null): Int64 = 0;
	static var retainListLast: Null<Retainer<Any>> = null;
	static var retainListMutex = new Mutex();

	public final value: T;

	var listPrevious: Null<Retainer<Any>> = null;
	var listNext: Null<Retainer<Any>> = null;
	var retained = true;

	public function new(value: T) {
		this.value = value;

		retainListMutex.acquire();
		// retain
		if (retainListLast != null) {
			retainListLast.listNext = this;
			listPrevious = retainListLast;
		}
		retainListLast = this;
		retainedCount++;
		retainListMutex.release();
	}

	/**
		Informs the garbage collector that an external reference is no longer required and the object in the value field may be collected (if no other haxe references remain)

		Only call this if the value is no-longer required by C
	**/
	public function release() {
		if (retained) {
			retainListMutex.acquire();
			// cut this item out of the list and stitch up
			if (listPrevious != null) {
				listPrevious.listNext = listNext;
			}
			if (listNext != null) {
				listNext.listPrevious = listPrevious;
			} else {
				// last item in the list
				retainListLast = listPrevious;
			}
			listNext = null;
			listPrevious = null;
			retained = false;
			retainedCount--;
			retainListMutex.release();
		}
	}

}

#if (haxe_ver >= 4.2)
@:forward
@:access(sys.thread.EventLoop)
abstract CustomEventLoop(sys.thread.EventLoop) from sys.thread.EventLoop {

	// same as __progress but it doesn't reset the wait lock
	// this is because resetting the wait lock here can mean wake-up lock releases are missed
	// and we cannot resolve by only waking up with in the mutex because this interacts with the hxcpp GC (and we want to wake-up from a non-hxcpp-attached thread)
	public inline function customProgress(now:Float, recycle:Array<()->Void>):{nextEventAt:Float, anyTime:Bool} {
		var eventsToRun = recycle;
		var eventsToRunIdx = 0;
		// When the next event is expected to run
		var nextEventAt:Float = -1;

		this.mutex.acquire();
		// @edit: don't reset the wait lock (see above)
		// while(waitLock.wait(0.0)) {}
		// Collect regular events to run
		var current = this.regularEvents;
		while(current != null) {
			if(current.nextRunTime <= now) {
				eventsToRun[eventsToRunIdx++] = current.run;
				current.nextRunTime += current.interval;
				nextEventAt = -2;
			} else if(nextEventAt == -1 || current.nextRunTime < nextEventAt) {
				nextEventAt = current.nextRunTime;
			}
			current = current.next;
		}
		this.mutex.release();

		// Run regular events
		for(i in 0...eventsToRunIdx) {
			eventsToRun[i]();
			eventsToRun[i] = null;
		}
		eventsToRunIdx = 0;

		// Collect pending one-time events
		this.mutex.acquire();
		for(i => event in this.oneTimeEvents) {
			switch event {
				case null:
					break;
				case _:
					eventsToRun[eventsToRunIdx++] = event;
					this.oneTimeEvents[i] = null;
			}
		}
		this.oneTimeEventsIdx = 0;
		var hasPromisedEvents = this.promisedEventsCount > 0;
		this.mutex.release();

		//run events
		for(i in 0...eventsToRunIdx) {
			eventsToRun[i]();
			eventsToRun[i] = null;
		}

		// Some events were executed. They could add new events to run.
		if(eventsToRunIdx > 0) {
			nextEventAt = -2;
		}
		return {nextEventAt:nextEventAt, anyTime:hasPromisedEvents}
	}

}
#end

#end