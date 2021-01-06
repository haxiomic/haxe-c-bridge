import haxe.macro.TypedExprTools;
import haxe.macro.ExprTools;
#if macro

import sys.FileSystem;
import sys.io.File;
import haxe.macro.Type;
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.ComplexTypeTools;
import haxe.macro.TypeTools;
import haxe.macro.Printer;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.ds.ReadOnlyArray;
import HaxeCInterface.CodeTools.*;

using Lambda;
using StringTools;

class HaxeCInterface {

	static final isDisplay = Context.defined('display') || Context.defined('display-details');
	static final noOutput = Sys.args().has('--no-output');
	static final printer = new Printer();
	
	static var isOnAfterGenerateSetup = false;

	static final projectName = determineProjectName();

	static final cConversionContext = new CConverterContext({
		declarationPrefix: projectName,
		generateTypedef: true,
		generateTypedefWithTypeParameters: false,
	});

	static public function build(?namespace: String) {
		var fields = Context.getBuildFields();

		if (isDisplay) return fields;
		if (Context.definedValue('target.name') != 'cpp') return fields;

		if (!isOnAfterGenerateSetup) {
			setupOnAfterGenerate();
		}

		var cls = Context.getLocalClass().get();
		cls.meta.add(':keep', [], cls.pos);

		var typeNamespace =
				[projectName]
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
				var cFuncName = typeNamespace.concat([f.name]).join('_');
				cConversionContext.addFunctionDeclaration(cFuncName, fun.args, fun.ret, f.doc, f.pos);

				var fnName = f.name;
				var fnRetType = fun.ret;
				var isRetVoid = isVoid(fun.ret);

				var argIdentList = fun.args.map(a -> macro $i{a.name});
				var callFn = macro $i{fnName}($a{argIdentList});

				var prefix = '__mainThreadSync__';

				var runnerFnName = '${prefix}${f.name}_run';
				var runnerLockName = '${prefix}${f.name}_lock';
				var runnerMutexName = '${prefix}${f.name}_mutex';
				var runnerReturnName = '${prefix}${f.name}_rtn';
				var runnerFields = (macro class {
					static var $runnerLockName = new sys.thread.Lock();
					static var $runnerMutexName = new sys.thread.Mutex();

					static function $runnerFnName() {
						try {
							// ${isRetVoid ? callFn : macro rtn = $callFn};
							// todo - execute call
							$i{runnerLockName}.release();
						} catch(e: Any) {
							$i{runnerLockName}.release();
							throw e;
						}
					}
				}).fields;

				if (!isRetVoid) {
					runnerFields.push((macro class {
						static var $runnerReturnName: $fnRetType;
					}).fields[0]);
				}

				var threadSafeFnName = '$prefix${f.name}';
				// add thread-safe call implementation
				var threadSafeFunction = (macro class {
					@:noCompletion
					static public function $threadSafeFnName (/* arguments must be defined manually */): $fnRetType {
						if (sys.thread.Thread.current() == @:privateAccess haxe.EntryPoint.mainThread) {
							${isRetVoid ? macro $callFn : macro return $callFn};
						}

						$i{runnerMutexName}.acquire();
						haxe.EntryPoint.runInMainThread($i{runnerFnName});
						$i{runnerLockName}.wait();
						$i{runnerMutexName}.release();
						${isRetVoid ? macro null : macro return $i{runnerReturnName}};
					}
				}).fields[0];

				// define arguments
				var threadSafeFunction = threadSafeFunction;
				switch threadSafeFunction.kind {
					case FFun(tsf):
						tsf.args = fun.args;
					default:
				}

				// add new fields to class
				for (f in runnerFields) newFields.push(f);
				newFields.push(threadSafeFunction);
			}
		}

		// generate a header file for this class with the listed C methods
		// generate an implementation for this class which calls sendMessageSync(function-id, args-as-payload)
		// be careful to respect :native
		// add to :buildXml 
			// - include C->C++ binding implementation
			// - copy generated header to include/

		return fields.concat(newFields);
	}

	static function setupOnAfterGenerate() {
		if (!noOutput) {
			Context.onAfterGenerate(() -> {
				var outputDirectory = getOutputDirectory(); 

				var header = generateHeader(cConversionContext, projectName);
				var headerPath = Path.join([outputDirectory, '$projectName.h']);

				touchDirectoryPath(outputDirectory);
				sys.io.File.saveContent(headerPath, header);
			});
		}

		isOnAfterGenerateSetup = true;
	}

	static function generateHeader(ctx: CConverterContext, namespace: String) {
		return code('
			/* $namespace.h */

			#ifndef ${namespace}_h
			#define ${namespace}_h

			')

			+ (if (ctx.includes.length > 0) ctx.includes.map(CPrinter.printInclude).join('\n') + '\n\n'; else '')
			+ (if (ctx.macros.length > 0) ctx.macros.join('\n') + '\n' else '')
			+ (if (ctx.typeDeclarations.length > 0) ctx.typeDeclarations.map(CPrinter.printDeclaration).join(';\n') + ';\n\n'; else '')

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
				**/
				char* ${namespace}_startHaxeThread(HaxeExceptionCallback fatalExceptionCallback);

				/**
				 * Ends the haxe thread after it finishes processing pending events (events scheduled in the future will not be executed)
				 * 
				 * Blocks until the haxe thread has finished
				 * 
				 * `${namespace}_startHaxeThread` may be used to reinitialize the thread. Haxe main() will be called for a second time and all state from the previous execution will be lost
				 * 
				 * Thread-safety: May be called on a different thread to `${namespace}_startHaxeThread` but must not be called from the haxe thread
				**/
				void ${namespace}_stopHaxeThread();

		')

		+ indent(1, ctx.functionDeclarations.map(fn -> CPrinter.printDeclaration(fn)).join(';\n\n') + ';\n\n')

		+ code('
			#ifdef __cplusplus
			}
			#endif

			#endif /* ${namespace}_h */
		');
	}

	static function doc(str: String) {
		str = code(str).rtrim();
		str = str.split('\n').map(l -> ' * $l').join('\n');
		return str + '\n';
	}

	/**
		We determine a project name to be the `--main` startup class or the first specified class-path

		The user can override this with `-D haxe-embed-name=ExampleName`

		This isn't rigorously defined but hopefully will produced nicely namespaced and unsurprising function names
	**/
	static function determineProjectName(): Null<String> {
		var overrideName = Context.definedValue('haxe-embed-name');
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

	/**
		Ensures directory structure exists for a given path
		(Same behavior as mkdir -p)
		@throws Any
	**/
	static public function touchDirectoryPath(path: String) {
		var directories = Path.normalize(path).split('/');
		var currentDirectories = [];
		for (directory in directories) {
			currentDirectories.push(directory);
			var currentPath = currentDirectories.join('/');
			if (currentPath == '/') continue;
			if (FileSystem.isDirectory(currentPath)) continue;
			if (!FileSystem.exists(currentPath)) {
				FileSystem.createDirectory(currentPath);
			} else {
				throw 'Could not create directory $currentPath because a file already exists at this path';
			}
		}
	}

	static function getOutputDirectory() {
		var directoryTargets = [ 'as3', 'php', 'cpp', 'cs', 'java' ];
		return directoryTargets.has(Context.definedValue('target.name')) ? Compiler.getOutput() : Path.directory(Compiler.getOutput());
	}

	static final _voidType = Context.getType('Void');
	static function isVoid(ct: ComplexType) {
		return Context.unify(ComplexTypeTools.toType(ct), _voidType);
	}


}

enum CModifier {
	Const;
}

enum CType {
	Ident(name: String, ?modifiers: Array<CModifier>);
	Pointer(t: CType, ?modifiers: Array<CModifier>);
	FunctionPointer(name: String, argTypes: Array<CType>, ret: CType, ?modifiers: Array<CModifier>);
}

// not exactly specification C but good enough for this purpose
enum CDeclarationKind {
	Typedef(type: CType, declarators: Array<String>);
	Enum(name: String, fields: Array<{name: String, ?value: Int}>);
	Function(name: String, args: Array<{name: String, type: CType}>, ret: CType);
}

typedef CDeclaration = {
	kind: CDeclarationKind,
	?doc: String,
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
		}
	}

	public static function printDeclaration(cDeclaration: CDeclaration) {
		return
			(cDeclaration.doc != null ? (printDoc(cDeclaration.doc) + '\n') : '')
			+ switch cDeclaration.kind {
				case Typedef(type, declarators):
					'typedef ${printType(type)}' + (declarators.length > 0 ? ' ${declarators.join(', ')}' :'');
				case Enum(name, fields):
					'enum $name {\n'
					+ fields.map(f -> '\t' + f.name + (f.value != null ? ' = ${f.value}' : '')).join(',\n') + '\n'
					+ '}';
				case Function(name, args, ret):
					'${printType(ret)} $name(${args.map(arg -> '${printType(arg.type)} ${arg.name}').join(', ')})';
		}
	}

	public static function printDoc(doc: String) {
		return '/**\n$doc\n**/';
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
	final generateTypedefWithTypeParameters: Bool;

	/**
		namespace is used to prefix types
	**/
	public function new(options: {
		?declarationPrefix: String,
		?generateTypedef: Bool,
		/** type parameter name is appended to the typedef ident, this makes for long type names so it's disabled by default **/
		?generateTypedefWithTypeParameters: Bool,
	} = null) {
		this.declarationPrefix = (options != null && options.declarationPrefix != null) ? options.declarationPrefix : '';
		this.generateTypedef = (options != null && options.generateTypedef != null) ? options.generateTypedef : true;
		this.generateTypedefWithTypeParameters = (options != null && options.generateTypedefWithTypeParameters != null) ? options.generateTypedefWithTypeParameters : false;
	}

	public function addFunctionDeclaration(name: String, args: Array<FunctionArg>, ret: ComplexType, doc: Null<String>, pos: Position) {
		functionDeclarations.push({
			doc: doc,
			kind: Function(
				name,
				args.map(arg -> {
					name: cKeywords.has(arg.name) ? (arg.name + '_') : arg.name,
					type: convertComplexType(arg.type, pos)
				}),
				convertComplexType(ret, pos)
			)
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
								var targetFilePath = Path.join([Compiler.getOutput(), filename]);
								File.copy(absoluteIncludePath, targetFilePath);
								requireHeader(filename, true);
							default:
						}
					}
					Ident(ident);
				} else {
					Context.fatalError('Could not convert type "${TypeTools.toString(type)}" to C representation', pos);
				}

			case TFun(args, ret):
				if (allowBareFnTypes) {
					getFunctionCType(args, ret, pos);
				} else {
					Context.fatalError("Callbacks must be wrapped in cpp.Callable<T> when exposing to C", pos);
				}

			case TAnonymous(a):
				Context.fatalError("Haxe structures are not supported when exposing to C, try using an extern for a C struct instead", pos);

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
					if (isIntEnumAbstract) {
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
				Context.fatalError("Dynamic is not supported when exposing to C", pos);
			
			case TMono(t):
				Context.fatalError("Explicit type is required when exposing to C", pos);

			case TEnum(t, params):
				Context.fatalError("Exposing enum types to C is not supported, try using an enum abstract over Int", pos);
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
					Context.fatalError("Null<T> is not supported for C export", pos);
				case {t: {pack: [], name: "Array"}}:
					Context.fatalError("Array<T> is not supported for C export, try using cpp.Pointer<T> instead", pos);

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
					Context.fatalError('cpp.$name is not supported for C export', pos);

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

	function getValue(expr: Expr) {
		return switch expr.expr {
			case ECast(e, t):
				getValue(e);
			default: ExprTools.getValue(expr);
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
		if (!declaredTypeIdentifiers.exists(ident)) {
			
			var funcPointer: CType = FunctionPointer(
				ident,
				args.map(arg -> convertType(arg.t, false, pos)),
				convertType(ret, false, pos)
			);
			typeDeclarations.push({kind: Typedef(funcPointer, []) });
			declaredTypeIdentifiers.set(ident, true);
			
		}
		return Ident(ident);
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

	static public final cKeywords: ReadOnlyArray<String> = [
		"auto", "double", "int", "struct", "break", "else", "long", "switch", "case", "enum", "register", "typedef", "char", "extern", "return", "union", "const", "float", "short", "unsigned", "continue", "for", "signed", "void", "default", "goto", "sizeof", "volatile", "do", "if", "static", "while",
		"size_t", "int64_t", "uint64_t"
	];

}

class ComplexTypeMap {

	/**
		Transforms a ComplexType recursively
		Does not explore expressions contained within types (like anon fields)
	**/
	static public function map(complexType: Null<ComplexType>, f: ComplexType -> ComplexType): ComplexType {
		if (complexType == null) {
			return null;
		}

		return switch complexType {
			case TFunction(args, ret):
				f(TFunction(args.map(a -> map(a, f)), map(ret, f)));
			case TParent(t):
				f(TParent(map(t, f)));
			case TOptional(t):
				f(TOptional(map(t, f)));
			case TNamed(n, t):
				f(TNamed(n, map(t, f)));
			case TIntersection(types):
				f(TIntersection(types.map(t -> map(t, f))));
			case TAnonymous(fields):
				f(TAnonymous(fields.map(field -> mapField(field, f))));
			case TExtend(ap, fields):
				f(TExtend(ap.map(p -> mapTypePath(p, f)), fields.map(field -> mapField(field, f))));
			case TPath(p):
				f(TPath(mapTypePath(p, f)));
		}
	}

	static public function mapTypePath(typePath: TypePath, f: ComplexType -> ComplexType): TypePath {
		return {
			pack: typePath.pack,
			name: typePath.name,
			sub: typePath.sub,
			params: typePath.params != null ? typePath.params.map(tp -> switch tp {
				case TPType(t): TPType(map(t, f));
				case TPExpr(e): TPExpr(e);
			}) : null,
		}
	}

	static public function mapArg(arg: FunctionArg, f: ComplexType -> ComplexType): FunctionArg {
		return {
			name: arg.name,
			meta: arg.meta,
			value: arg.value,
			opt: arg.opt,
			type: map(arg.type, f)
		}
	}

	static public function mapFunction(fun: Function, f: ComplexType -> ComplexType): Function {
		return {
			params: fun.params,
			expr: fun.expr,
			args: fun.args.map(a -> mapArg(a, f)),
			ret: map(fun.ret, f),
		}
	}

	static public function mapField(field: Field, f: ComplexType -> ComplexType): Field {
		return {
			name: field.name,
			meta: field.meta,
			pos: field.pos,
			access: field.access,
			doc: field.doc,
			kind: switch field.kind {
				case FVar(t, e): FVar(map(t, f), e);
				case FFun(fun): FFun(mapFunction(fun, f));
				case FProp(get, set, t, e):FProp(get, set, map(t, f), e);
			}
		};
	}

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

#end