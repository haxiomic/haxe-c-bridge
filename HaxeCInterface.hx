#if macro

#if ((display || display_details || target.name != cpp) && false)
// fast path for when code gen isn't required
class HaxeCInterface {
	public static function build() {
		return Context.getBuildFields();
	}
}

#else

import HaxeCInterface.CodeTools.*;
import haxe.ds.ReadOnlyArray;
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.Printer;
import haxe.macro.Type;
import haxe.macro.TypeTools;
import haxe.macro.TypedExprTools;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

class HaxeCInterface {

	static final noOutput = Sys.args().has('--no-output');
	static final printer = new Printer();
	
	static var isOnAfterGenerateSetup = false;

	static final libName = determineLibName();
	static final compilerOutputDir = Compiler.getOutput();
	// paths relative to the compiler output directory
	static final headerPath = Path.join(['$libName.h']);
	static final implementationPath = Path.join(['src', '__${libName}__.cpp']);

	static final implementationHeaders = new Array<CInclude>();
	static final cConversionContext = new CConverterContext({
		declarationPrefix: libName,
		generateTypedef: true,
		generateTypedefWithTypeParameters: false,
	});
	static final functionMap = new Map<String, {
		hxcppName: String,
		fun: Function,
		field: Field,
		rootCTypes: {
			args: Array<CType>,
			ret: CType
		},
		pos: Position,
	}>();

	static public function build(?namespace: String) {
		var fields = Context.getBuildFields();

		// resolve runtime HaxeCInterface class to make sure it's generated
		// add @:buildXml to include generated code
		var HaxeCInterfaceType = Context.resolveType(macro :HaxeCInterface, Context.currentPos());
		switch HaxeCInterfaceType {
			case TInst(_.get().meta => meta, params):
				if (!meta.has(':buildXml')) {
					meta.add(':buildXml', [{
						expr: EConst(CString('
							<!-- HaxeCInterface -->
							<files id="haxe">
								<file name="$implementationPath">
									<depend name="$headerPath"/>
								</file>
							</files>
						')),
						pos: Context.currentPos()
					}], Context.currentPos());
				}
			default: throw 'Internal error';
		}

		var cls = Context.getLocalClass().get();

		// add @:keep
		cls.meta.add(':keep', [], cls.pos);
		
		// determine the name of the class as generated by hxcpp
		var isNativeGen = cls.meta.has(':nativeGen');
		var nativeMeta = cls.meta.extract(':native')[0];
		var nativeMetaValue = nativeMeta != null ? ExprTools.getValue(nativeMeta.params[0]) : null;
		var nativeName = (nativeMetaValue != null ? nativeMetaValue : cls.pack.concat([cls.name]).join('.'));
		var nativeHxcppName = nativeName + (isNativeGen ? '' : '_obj');

		// determine the hxcpp generated header path for this class
		var typeHeaderPath = nativeName.split('.');
		implementationHeaders.push({path: Path.join(typeHeaderPath) + '.h', quoted: false});

		// prefix all functions with lib name and class path
		var functionPrefix =
				[libName]
				.concat(cls.pack)
				.concat([namespace == null ? cls.name : namespace])
				.filter(s -> s != '');
		
		var newFields = new Array<Field>();

		for (f in fields) {
			var fun = switch f.kind {case FFun(f): f; default: null;};

			if (fun != null && f.access.has(AStatic) && f.access.has(APublic)) {
				// validate signature
				if (fun.params.length > 0) {
					Context.error('Type parameters are unsupported for functions exposed to C', f.pos);
				}
				if (fun.ret == null) {
					Context.error('Explicit return type is required for functions exposed to C', f.pos);
				}
				for (arg in fun.args) {
					if (arg.type == null) {
						Context.error('Explicit type for argument ${arg.name} is required for functions exposed to C', f.pos);
					}
				}

				// add C function declaration
				var cFuncName = functionPrefix.concat([f.name]).join('_');
				var cleanDoc = f.doc != null ? StringTools.trim(removeIndentation(f.doc)) : null;
				cConversionContext.addFunctionDeclaration(cFuncName, fun.args, fun.ret, cleanDoc, f.pos);

				inline function getRootCType(ct: ComplexType) {
					var tmpCtx = new CConverterContext({generateTypedef: false, generateTypedefForFunctions: false, generateEnums: false});
					return tmpCtx.convertType(
						Context.resolveType(ct, f.pos),
						true,
						f.pos
					);
				}

				functionMap.set(cFuncName, {
					hxcppName: nativeHxcppName.split('.').join('::') + '::' + f.name,
					fun: fun,
					field: f,
					rootCTypes: {
						args: fun.args.map(a -> getRootCType(a.type)),
						ret: getRootCType(fun.ret)
					},
					pos: f.pos
				});
			}
		}

		if (!isOnAfterGenerateSetup) {
			if (!noOutput) {
				Context.onAfterGenerate(() -> {
					var header = generateHeader(cConversionContext, libName);
					var implementation = generateImplementation(cConversionContext, libName);

					if (!FileSystem.exists(compilerOutputDir)) {
						FileSystem.createDirectory(compilerOutputDir);
					}
					sys.io.File.saveContent(Path.join([compilerOutputDir, headerPath]), header);
					sys.io.File.saveContent(Path.join([compilerOutputDir, implementationPath]), implementation);
				});
			}

			isOnAfterGenerateSetup = true;
		}

		return fields.concat(newFields);
	}


	static function generateHeader(ctx: CConverterContext, namespace: String) {
		var hasLibLink = Context.defined('dll_link') || Context.defined('static_link');
		return code('
			/**
			 * $namespace.h
			 * ${hasLibLink ? 
			 	'Automatically generated by HaxeCInterface' :
				'! Warning, hxcpp project not generated as a library, make sure to add `-D dll_link` or `-D static_link` when compiling the haxe project !'
				}
			 */

			#ifndef ${namespace}_h
			#define ${namespace}_h

			')

			+ (if (ctx.includes.length > 0) ctx.includes.map(CPrinter.printInclude).join('\n') + '\n\n'; else '')
			+ (if (ctx.macros.length > 0) ctx.macros.join('\n') + '\n' else '')
			+ (if (ctx.typeDeclarations.length > 0) ctx.typeDeclarations.map(d -> CPrinter.printDeclaration(d, true)).join(';\n') + ';\n\n'; else '')

			+ code('
			typedef void (* HaxeExceptionCallback) (const char* exceptionInfo);

			#ifdef __cplusplus
			extern "C" {
			#endif

				/**
				 * Initializes a haxe thread that remains alive indefinitely and executes the user\'s haxe main()
				 * 
				 * This must be called before sending messages
				 * 
				 * It may be called again if `${namespace}_stopHaxeThread` is used to end the current haxe thread first (all state from the previous execution will be lost)
				 * 
				 * Thread-safe
				 * 
				 * @param fatalExceptionCallback a callback to execute if a fatal unhandled exception occurs on the haxe thread. This will be executed on the haxe thread immediately before it ends. You may use this callback to start a new haxe thread. Use `NULL` for no callback
				 * @returns `NULL` if the thread initializes successfully or a null terminated C string with exception if an exception occurs during initialization
				 */
				const char* ${namespace}_startHaxeThread(HaxeExceptionCallback fatalExceptionCallback);

				/**
				 * Ends the haxe thread after it finishes processing pending events (events scheduled in the future will not be executed)
				 * 
				 * Blocks until the haxe thread has finished
				 * 
				 * `${namespace}_startHaxeThread` may be used to reinitialize the thread. Haxe main() will be called for a second time and all state from the previous execution will be lost
				 * 
				 * Thread-safety: May be called on a different thread to `${namespace}_startHaxeThread` but must not be called from the haxe thread
				 */
				void ${namespace}_stopHaxeThread();

		')

		+ indent(1, ctx.functionDeclarations.map(fn -> CPrinter.printDeclaration(fn, true)).join(';\n\n') + ';\n\n')

		+ code('
			#ifdef __cplusplus
			}
			#endif

			#endif /* ${namespace}_h */
		');
	}

	static function generateImplementation(ctx: CConverterContext, namespace: String) {
		return code('
			/* ${namespace}.cpp */
			#include <hxcpp.h>
			#include <hx/Native.h>
			#include <hx/Thread.h>
			#include <hx/StdLibs.h>
			#include <HaxeCInterface.h>
			#include <_HaxeCInterface/EndThreadException.h>

			#include "../${namespace}.h"

		')
		+ implementationHeaders.map(CPrinter.printInclude).join('\n') + '\n'
		+ code('

			extern "C" void __hxcpp_main();

			bool threadInitialized = false;
			const char* threadInitExceptionInfo = nullptr;
			HxSemaphore threadInitSemaphore;
			HxSemaphore threadEndSemaphore;
			HxMutex threadManageMutex;

			HaxeExceptionCallback haxeExceptionCallback = nullptr;

			THREAD_FUNC_TYPE haxeMainThreadFunc(void *data) {
				// reset the exception info
				threadInitExceptionInfo = nullptr;

				// See hx::Init in StdLibs.cpp for reference
				try {

					HX_TOP_OF_STACK
					::hx::Boot();
					__boot_all();

				} catch(Dynamic initException) {

					// hxcpp init failure or uncaught haxe runtime exception
					HX_TOP_OF_STACK
					threadInitExceptionInfo = initException->toString().utf8_str();

				}

				threadInitSemaphore.Set();

				if (threadInitExceptionInfo == nullptr) { // initialized without error
					try {

						// this will block until all pending events created from main() have completed
						__hxcpp_main();

						// we want to keep alive the thread after main() has completed, so we run the event loop until we want to terminate the thread
						HaxeCInterface::endlessEventLoop();

					} catch(Dynamic runtimeException) {

						// An EndThreadException is used to break out of the event loop, we do not need to report this exception
						if (!runtimeException.IsClass<_HaxeCInterface::EndThreadException>()) {
							if (haxeExceptionCallback != nullptr) {
								const char* info = runtimeException->toString().utf8_str();
								haxeExceptionCallback(info);
							}
						}

					}
				}

				threadEndSemaphore.Set();

				THREAD_FUNC_RET
			}

			HXCPP_EXTERN_CLASS_ATTRIBUTES
			const char* ${namespace}_startHaxeThread(HaxeExceptionCallback unhandledExceptionCallback) {
				threadManageMutex.Lock();

				if (threadInitialized) return nullptr;

				haxeExceptionCallback = unhandledExceptionCallback;

				// startup the haxe main thread
				HxCreateDetachedThread(haxeMainThreadFunc, nullptr);

				// wait until the thread is initialized and ready
				threadInitSemaphore.Wait();

				threadInitialized = true;

				threadManageMutex.Unlock();

				return threadInitExceptionInfo;
			}

			HXCPP_EXTERN_CLASS_ATTRIBUTES
			void ${namespace}_stopHaxeThread() {
				threadManageMutex.Lock();

				if (!threadInitialized) return;

				hx::NativeAttach autoAttach;

				// queue an exception into the event loop so we break out of the loop and end the thread
				HaxeCInterface::endThread(HaxeCInterface::getMainThread());

				// block until the thread ends, the haxe thread will first execute all immediately pending events
				threadEndSemaphore.Wait();

				threadInitialized = false;

				threadManageMutex.Unlock();
			}

		')
		+ ctx.functionDeclarations.map(generateFunctionImplementation).join('\n') + '\n'
		;
	}

	static function generateFunctionImplementation(d: CDeclaration) {
		var signature = switch d.kind {case Function(sig): sig; default: null;};
		var haxeFunction = functionMap.get(signature.name);
		var hasReturnValue = !haxeFunction.rootCTypes.ret.match(Ident('void'));
		var externalThread = if (haxeFunction.field.meta != null) {
			haxeFunction.field.meta.exists(m -> m.name == 'externalThread');
		} else false;

		inline function callWithArgs(argStrs: Array<String>) {
			return '${haxeFunction.hxcppName}(${
				argStrs.mapi((i, arg) -> {
					// type cast argument before passing to hxcpp
					var rootCType = haxeFunction.rootCTypes.args[i];
					switch rootCType {
						case Ident(name, _): arg; // basic C type, no cast needed
						case Pointer(t, _):  '(${CPrinter.printType(rootCType)}) $arg'; // cast to root C type for better handling by hxcpp types
						case FunctionPointer(name, argTypes, ret, _): 'hx::AnyCast(${arg})'; // functions can use AnyCast to force cast to cpp::Function
						case InlineStruct(_): arg;
					}
				}).join(', ')
			})';
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
			var runnerSignature: CFunctionSignature = {
				name: '__runner__${signature.name}',
				args: [{type: Pointer(Ident('void')), name: 'data'}],
				ret: Ident('void')
			}
			var lockName = '__lock__${signature.name}';
			var fnDataTypeName = 'FnData__${signature.name}';
			var fnDataStruct: CStruct = {
				fields: [
					{
						name: 'args',
						type: InlineStruct({fields: signature.args})
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
				code(CPrinter.printDeclaration(fnDataDeclaration) + ';')
				+ code('

					HxSemaphore ${lockName};
					${CPrinter.printFunctionSignature(runnerSignature)} {
						$fnDataTypeName* fnData = ($fnDataTypeName*) data;
						${hasReturnValue ? 'fnData->ret = ' : ''}${callWithArgs(signature.args.map(a->'fnData->args.${a.name}'))};
						${lockName}.Set();
					}
				')
				+ code('
					HXCPP_EXTERN_CLASS_ATTRIBUTES
				')
				+ CPrinter.printDeclaration(d, false)
				+ code('
					{
						hx::NativeAttach autoAttach;
						if (HaxeCInterface::isMainThread()) {
							return ${callWithArgs(signature.args.map(a->a.name))};
						}

						$fnDataTypeName fnData = { {${signature.args.map(a->a.name).join(', ')}} };
				')
				+ code('
						HaxeCInterface::queueOnMainThread(${runnerSignature.name}, &fnData);
						${lockName}.Wait();
						${hasReturnValue ? 'return fnData.ret;' : ''}
					}
				')
			);
		}
	}

	/**
		We determine a project name to be the `--main` startup class or the first specified class-path

		The user can override this with `-D c-api-name=ExampleName`

		This isn't rigorously defined but hopefully will produced nicely namespaced and unsurprising function names
	**/
	static function determineLibName(): Null<String> {
		var overrideName = Context.definedValue('c-api-name');
		if (overrideName != null && overrideName != '') {
			return safeIdent(overrideName);
		}

		var args = Sys.args();

		// return -m {path} or --main {class-path}
		for (i in 0...args.length) {
			var arg = args[i];
			if (arg == '-m' || arg == '--main') {
				var classPath = args[i + 1];
				return safeIdent(classPath);
			}
		}

		// if no main is found, use first direct class reference
		for (i in 0...args.length) {
			var arg = args[i];
			if (arg.charAt(0) != '-') {
				var argBefore = args[i - 1];
				// is this value preceded by a flag? If not, it's a lone value and therefore a class-path
				var isLoneValue = if (argBefore != null) {
					argBefore.charAt(0) != '-';
				} else true;
				if (isLoneValue) {
					return safeIdent(arg);
				}
			}
		}

		// default to HaxeLibrary
		return 'HaxeLibrary';
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
		return '/**\n${doc.split('\n').map(l -> ' * $l').join('\n')}\n */';
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

	public final typeDeclarations = new Array<CDeclaration>();
	final declaredTypeIdentifiers = new Map<String, Bool>();
	
	public final functionDeclarations = new Array<CDeclaration>();
	
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

	public function addFunctionDeclaration(name: String, args: Array<FunctionArg>, ret: ComplexType, doc: Null<String>, pos: Position) {
		functionDeclarations.push({
			doc: doc,
			kind: Function({
				name: name,
				args: args.map(arg -> {
					name: cKeywords.has(arg.name) ? (arg.name + '_') : arg.name,
					type: convertComplexType(arg.type, pos)
				}),
				ret: convertComplexType(ret, pos)
			})
		});
	}

	public function convertComplexType(ct: ComplexType, pos: Position) {
		return convertType(Context.resolveType(ct, pos), false, pos);
	}

	public function convertType(type: Type, allowBareFnTypes: Bool, pos: Position): CType {
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
			return convertKeyType(type, allowBareFnTypes, pos);
		}
		
		return switch type {
			case TInst(_.get() => t, _):
				var keyCType = tryConvertKeyType(type, allowBareFnTypes, pos);
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
					Context.error('Could not convert type "${TypeTools.toString(type)}" to C representation', pos);
				}

			case TFun(args, ret):
				if (allowBareFnTypes) {
					getFunctionCType(args, ret, pos);
				} else {
					Context.error("Callbacks must be wrapped in cpp.Callable<T> when exposing to C", pos);
				}

			case TAnonymous(a):
				Context.error("Haxe structures are not supported when exposing to C, try using an extern for a C struct instead", pos);

			case TAbstract(_.get() => t, _):
				var keyCType = tryConvertKeyType(type, allowBareFnTypes, pos);
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
						getEnumCType(type, pos);
					} else {
						// follow once abstract's underling type
						convertType(TypeTools.followWithAbstracts(type, true), allowBareFnTypes, pos);
					}
				}
			
			case TType(_.get() => t, params):
				var keyCType = tryConvertKeyType(type, allowBareFnTypes, pos);
				if (keyCType != null) {
					keyCType;
				} else {

					var useDeclaration =
						generateTypedef &&
						(params.length > 0 ? generateTypedefWithTypeParameters : true) &&
						!t.isPrivate;

					if (useDeclaration) {
						getTypeAliasCType(type, allowBareFnTypes, pos);
					} else {
						// follow type alias (with type parameter)
						convertType(TypeTools.follow(type, true), allowBareFnTypes, pos);
					}
				}

			case TLazy(f):
				convertType(f(), allowBareFnTypes, pos);

			case TDynamic(t):
				Context.error("Dynamic is not supported when exposing to C", pos);
			
			case TMono(t):
				Context.error("Explicit type is required when exposing to C", pos);

			case TEnum(t, params):
				Context.error("Exposing enum types to C is not supported, try using an enum abstract over Int", pos);
		}
	}

	/**
		Convert a key type and expect a result (or fail)
		A key try is like a core type (and includes :coreType types) but also includes hxcpp's own special types that don't have the :coreType annotation
	**/
	function convertKeyType(type: Type, allowBareFnTypes: Bool, pos: Position): CType {
		var keyCType = tryConvertKeyType(type, allowBareFnTypes, pos);
		return if (keyCType == null) {
			var p = new Printer();
			Context.warning('No corresponding C type found for "${TypeTools.toString(type)}" (using void* instead)', pos);
			Pointer(Ident('void'));
		} else keyCType;
	}

	/**
		Return CType if Type was a key type and null otherwise
	**/
	function tryConvertKeyType(type: Type, allowBareFnTypes: Bool, pos: Position): Null<CType> {
		var base = asBaseType(type);
		return if (base != null) {
			switch base {
				// special cases where we have to patch out the hxcpp types because they don't work with Context.resolveType
				case {t: {pack: [], name: 'CppVoid' }}: Ident('void');
				case {t: {pack: [], name: 'CppConstPointer' }, params: [tp]}: Pointer(setModifier(convertType(tp, allowBareFnTypes, pos), Const));

				/**
					See `cpp_type_of` in gencpp.ml
					https://github.com/HaxeFoundation/haxe/blob/65bb88834cea059035a73db48e79c7a5c5817ee8/src/generators/gencpp.ml#L1743
				**/

				case {t: {pack: [], name: "Null"}}:
					Context.error("Null<T> is not supported for C export", pos);
				case {t: {pack: [], name: "Array"}}:
					Context.error("Array<T> is not supported for C export, try using cpp.Pointer<T> instead", pos);

				case {t: {pack: [], name: 'Void' | 'void'}}: Ident('void');
				case {t: {pack: [], name: "Bool"}}: Ident("bool");
				case {t: {pack: [], name: "Float"}}: Ident("double");
				case {t: {pack: [], name: "Int"}}: Ident("int");
				case {t: {pack: [], name: "Single"}}: Ident("float");

				// needs explicit conversion internally
				case {t: {pack: [], name: "String"}}: Pointer(Ident("char", [Const]));

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

				case {t: {pack: ["cpp"], name: "Star" | "RawPointer" | "Pointer"}, params: [tp]}: Pointer(convertType(tp, allowBareFnTypes, pos));
				case {t: {pack: ["cpp"], name: "ConstStar" | "RawConstPointer" | "ConstPointer"}, params: [tp]}: Pointer(setModifier(convertType(tp, allowBareFnTypes, pos), Const));

				case {t: {pack: ["cpp"], name: "Callable" | "CallableData"}, params: [tp]}: convertType(tp, true, pos);
				case {t: {pack: ["cpp"], name: "Function"}, params: [tp, abi]}: convertType(tp, true, pos);

				case {t: {pack: ["cpp"], name: name =
					"Reference" |
					"AutoCast" |
					"VarArg" |
					"FastIterator"
				}}:
					Context.error('cpp.$name is not supported for C export', pos);

				// if the type is in the cpp package and has :native(ident), use that
				// this isn't ideal because the relevant C header may not be included
				// case {t: {pack: ['cpp'], meta: _.extract(':native') => [{params: [{expr: EConst(CString(nativeName))}]}] } }:
				// 	Ident(nativeName);

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
		}
	}

	function requireHeader(path: String, quoted: Bool = false) {
		if (!includes.exists(f -> f.path == path)) {
			includes.push({
				path: path,
				quoted: quoted
			});
		}
	}

	function getEnumCType(type: Type, pos: Position): CType {
		var ident = declarationPrefix + '_' + typeDeclarationIdent(type);

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
		return Ident(ident);
	}

	function getTypeAliasCType(type: Type, allowBareFnTypes: Bool, pos: Position): CType {
		var ident = declarationPrefix + '_' + typeDeclarationIdent(type);
		if (!declaredTypeIdentifiers.exists(ident)) {
			
			// order of typedef typeDeclarations should be dependency correct because required typedefs are added before this typedef is added
			var aliasedType = convertType(TypeTools.follow(type, true), allowBareFnTypes, pos);
			typeDeclarations.push({kind: Typedef(aliasedType, [ident])});
			declaredTypeIdentifiers.set(ident, true);
			
		}
		return Ident(ident);
	}

	function getFunctionCType(args: Array<{name: String, opt: Bool, t: Type}>, ret: Type, pos: Position): CType {
		// optional type parameters are not supported

		var ident = 'function_' + args.map(arg -> typeDeclarationIdent(arg.t)).concat([typeDeclarationIdent(ret)]).join('_');
		var funcPointer: CType = FunctionPointer(
			ident,
			args.map(arg -> convertType(arg.t, false, pos)),
			convertType(ret, false, pos)
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

	static public final cKeywords: ReadOnlyArray<String> = [
		"auto", "double", "int", "struct", "break", "else", "long", "switch", "case", "enum", "register", "typedef", "char", "extern", "return", "union", "const", "float", "short", "unsigned", "continue", "for", "signed", "void", "default", "goto", "sizeof", "volatile", "do", "if", "static", "while",
		"size_t", "int64_t", "uint64_t"
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

// runtime types

@:noCompletion
@:keep
private class EndThreadException extends haxe.Exception {}

@:nativeGen
@:keep
@:noCompletion
class HaxeCInterface {

	static inline function getMainThread(): sys.thread.Thread {
		return @:privateAccess haxe.EntryPoint.mainThread;
	}

	static public function isMainThread(): Bool {
		return sys.thread.Thread.current() == getMainThread();
	}

	static public function queueOnMainThread(fn: cpp.Callable<cpp.Star<cpp.Void> -> Void>, data: cpp.Star<cpp.Void>): Void {
		haxe.EntryPoint.runInMainThread(() -> {
			fn(data);
		});
	}

	/**
		Keeps the main thread event loop alive (even after all events and promises are exhausted)
	**/
	@:noCompletion
	static public function endlessEventLoop() {
		var current = sys.thread.Thread.current();
		while (true) {
			current.events.loop();
			current.events.wait();
		}
	}

	/**
		Break out of the event loop by throwing an end-thread exception
	**/
	@:noCompletion
	static public function endThread(thread: sys.thread.Thread) {
		thread.events.run(() -> {
			throw new EndThreadException('END-THREAD');
		});
	}

}

#end