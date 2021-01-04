#if macro

import sys.FileSystem;
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
	static var exposed = new Array<{
		cls: Ref<ClassType>,
		namespaceOverride: Null<String>,
		fields: Array<Field>
	}>();

	static public function build(?namespace: String) {
		var fields = Context.getBuildFields();

		if (isDisplay) return fields;

		if (!isOnAfterGenerateSetup) {
			setupOnAfterGenerate();
		}

		var cls = Context.getLocalClass().get();
		cls.meta.add(':keep', [], cls.pos);

		var exposedInfo = {
			cls: Context.getLocalClass(),
			namespaceOverride: namespace,
			fields: [],
		}

		var threadSafeFunctions = new Array<Field>();
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

				var fnName = f.name;
				var fnRetVoid = isVoid(fun.ret);

				var threadSafeFnName = '__threadSafeCApi__${f.name}';
				var argIdentList = fun.args.map(a -> macro $i{a.name});
				var fnCall = macro $i{fnName}($a{argIdentList});

				// add thread-safe call implementation
				var threadSafeFunction = (macro class {
					@:noCompletion
					static public function $threadSafeFnName(/* arguments must be defined manually */) {
						if (Thread.current() == @:privateAccess EntryPoint.mainThread) {
							${fnRetVoid ? macro $fnCall : macro return $fnCall};
						} else {
							var completionLock = new Lock();
							${fnRetVoid ? macro null : macro var rtn};
							EntryPoint.runInMainThread(() -> {
								try {
									${fnRetVoid ? fnCall : macro rtn = $fnCall};
									completionLock.release();
								} catch(e: Any) {
									completionLock.release();
									throw e;
								}
							});
							completionLock.wait();
							${fnRetVoid ? macro null : macro return rtn};
						}
					}
				}).fields[0];

				// define arguments
				switch threadSafeFunction.kind {
					case FFun(tsf):
						tsf.args = fun.args;
					default:
				}

				threadSafeFunctions.push(threadSafeFunction);

				exposedInfo.fields.push(f);
			}
		}

		exposed.push(exposedInfo);

		// generate a header file for this class with the listed C methods
		// generate an implementation for this class which calls sendMessageSync(function-id, args-as-payload)
		// be careful to respect :native
		// add to :buildXml 
			// - include C->C++ binding implementation
			// - copy generated header to include/

		return fields.concat(threadSafeFunctions);
	}

	static function setupOnAfterGenerate() {
		if (!noOutput) {
			Context.onAfterGenerate(() -> {
				var outputDirectory = getOutputDirectory(); 
				touchDirectoryPath(outputDirectory);

				var projectName = determineProjectName();

				var cTypeConverter = new CTypeConverterContext();

				var header = generateHeader(cTypeConverter, projectName);
				var headerPath = Path.join([outputDirectory, '$projectName.h']);
				sys.io.File.saveContent(headerPath, header);
			});
		}

		isOnAfterGenerateSetup = true;
	}

	static function genCType(ctx: CTypeConverterContext, ct: ComplexType, pos: Position) {
		return CPrinter.printType(ctx.convertComplexType(ct, pos));
	}

	static function genCFunctionSignature(ctx: CTypeConverterContext, name: String, hxFun: Function, pos: Position) {
		var cArgList = hxFun.args.map(arg ->
			'${genCType(ctx, arg.type, pos)} ${!CTypeConverterContext.cKeywords.has(arg.name) ? arg.name : arg.name + '_'}'
		);
		return '${genCType(ctx, hxFun.ret, pos)} $name(${cArgList.join(', ')});';
	}

	static function generateHeader(ctx: CTypeConverterContext, namespace: String) {
		var cFunSignatures = new Array<{doc: String, signature: String}>();

		for (info in exposed) {
			var cls = info.cls.get();

			var typeNamespace =
				[namespace]
				.concat(cls.pack)
				.concat([info.namespaceOverride == null ? cls.name : info.namespaceOverride])
				.filter(s -> s != '')
				.join('_');

			for (field in info.fields) {
				switch field.kind {
					case FFun(fun):
						cFunSignatures.push({
							doc: field.doc,
							signature: genCFunctionSignature(ctx, '${typeNamespace}_${field.name}', fun, field.pos)
						});
					case kind:
						throw 'Unsupported field kind "$kind"';
				}
			}
		}

		return code('
			/* $namespace.h */

			#ifndef ${namespace}_h
			#define ${namespace}_h

			')

			+ (if (ctx.includes.length > 0) ctx.includes.map(CPrinter.printInclude).join('\n') + '\n\n'; else '')
			+ (if (ctx.macros.length > 0) ctx.macros.join('\n') + '\n' else '')

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

		+ indent(1, 
			cFunSignatures.map(s -> {
				(s.doc != null ?
					code('
						/**
					')
					+ doc(s.doc)
					+ code('
						**/
					')
				: '')
				+ code('
					${s.signature}
				');
			}).join('\n')
		)

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
			case Ident(name, modifiers): (hasModifiers(modifiers) ? (printModifiers(modifiers) + ' ') : '') + name;
			case Pointer(t, modifiers): printType(t) + '*' + (hasModifiers(modifiers) ? (' ' + printModifiers(modifiers)) : '');
		}
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

class CTypeConverterContext {

	public final includes = new Array<CInclude>();
	public final macros = new Array<String>();

	public function new() {
	}

	public function convertComplexType(ct: ComplexType, pos: Position) {
		return convertType(resolveType(ct, pos), pos);
	}

	public function convertType(type: Type, pos: Position): CType {
		var hasCoreTypeIndication = {
			var baseType = asBaseType(type);
			if (baseType != null) {
				var t = baseType.t;
				// externs in the cpp pacakge are expected to be key-types
				t.isExtern && (t.pack[0] == 'cpp') ||
				t.meta.has(":coreType") ||
				// hxcpp doesn't mark its types as :coreType but uses :semantics and :noPackageRestrict sometimes
				t.meta.has(":semantics") ||
				t.meta.has(":noPackageRestrict");
			} else false;
		}

		if (hasCoreTypeIndication) {
			return convertKeyType(type, pos);
		}
		
		return switch type {
			case TInst(t, _):
				var keyCType = tryConvertKeyType(type, pos);
				keyCType != null ? keyCType : {
					Context.warning('- todo $type', pos);
					Ident('/*${type}*/void*');
				}

			case TFun(args, ret):
				Context.fatalError("Callbacks must be wrapped in cpp.Callable<T> when exposing to C", pos);

			case TAnonymous(a):
				Context.warning('- todo $type', pos);
				Ident('/*${type}*/void* ');

			case TAbstract(_.get() => t, _):
				var isEnumAbstract = t.meta.has(':enum');
				if (isEnumAbstract) Context.warning('- todo - EnumAbstract for $type', pos);
				var keyCType = tryConvertKeyType(type, pos);
				if (keyCType != null) {
					keyCType;
				} else {
					// follow alias
					convertType(TypeTools.followWithAbstracts(type, true), pos);
				}
			
			case TType(_.get() => t, _):
				var keyCType = tryConvertKeyType(type, pos);
				if (keyCType != null) {
					keyCType;
				} else {
					// follow once abstract's underling type
					convertType(TypeTools.follow(type, true), pos);
				}

			case TLazy(f):
				convertType(f(), pos);

			case TDynamic(t):
				Context.fatalError("Dynamic is not supported when exposing to C", pos);
			
			case TMono(t):
				Context.fatalError("Expected explicit type is required when exposing to C", pos);

			case TEnum(t, params):
				Context.fatalError("Exposing enum types to C is not supported", pos);
		}
	}

	function convertKeyType(type: Type, pos: Position): CType {
		var keyCType = tryConvertKeyType(type, pos);
		return if (keyCType == null) {
			var p = new Printer();
			Context.warning('No corresponding C type found for "${TypeTools.toString(type)}" (using void* instead)', pos);
			Pointer(Ident('void'));
		} else keyCType;
	}

	function tryConvertKeyType(type: Type, pos: Position): Null<CType> {
		var base = asBaseType(type);
		return if (base != null) {
			switch base {
				// special case for CppVoid
				case {t: {pack: [], name: 'CppVoid' }}: Ident('void');
				// special case for ConstPointer which seems to fail in Context.resolveType
				case {t: {pack: [], name: 'CppConstPointer' }, params: [tp]}: Pointer(setModifier(convertType(tp, pos), Const));

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

				case {t: {pack: ["cpp"], name: "Star" | "RawPointer" | "Pointer"}, params: [tp]}: Pointer(convertType(tp, pos));
				case {t: {pack: ["cpp"], name: "ConstStar" | "RawConstPointer" | "ConstPointer"}, params: [tp]}: Pointer(setModifier(convertType(tp, pos), Const));
				case {t: {pack: ["cpp"], name: "Reference"}}:
					Context.fatalError("cpp.Reference is not supported for C export", pos);

				// if the type is in the cpp package and has :native(ident), use that
				// this isn't ideal because the relevant C header may not be included
				// case {t: {pack: ['cpp'], meta: _.extract(':native') => [{params: [{expr: EConst(CString(nativeName))}]}]} }:
				// 	Ident(nativeName);

				default:
					// case {pack: [], name: "EnumValue"}: Ident
					// case {pack: [], name: "Class"}: Ident
					// case {pack: [], name: "Enum"}: Ident
					// case {pack: ["cpp"], name: "Object"}: Ident;

					// case {pack: ["cpp"], name: "VarArg"}: Ident;
					// case {pack: ["cpp"], name: "AutoCast"}: Ident;

					// | ([],"String"), [] ->
					// 			TCppString

					// (* Things with type parameters hxcpp knows about ... *)
					// | (["cpp"],"FastIterator"), [p] ->
					// 						TCppFastIterator(cpp_type_of stack ctx p)
					// | (["cpp"],"Function"), [function_type; abi] ->
					// 						cpp_function_type_of stack ctx function_type abi;
					// | (["cpp"],"Callable"), [function_type]
					// | (["cpp"],"CallableData"), [function_type] ->
					// 						cpp_function_type_of_string stack ctx function_type "";
					// | (("cpp"::["objc"]),"ObjcBlock"), [function_type] ->
					// 						let args,ret = (cpp_function_type_of_args_ret stack ctx function_type) in
					// 						TCppObjCBlock(args,ret)
					// | ((["cpp"]), "Rest"),[rest] ->
					// 						TCppRest(cpp_type_of stack ctx rest)
					// | (("cpp"::["objc"]),"Protocol"), [interface_type] ->
					// 						(match follow interface_type with
					// 						| TInst (klass,[]) when (has_class_flag klass CInterface) ->
					// 										TCppProtocol(klass)
					// 						(* TODO - get the line number here *)
					// 						| _ -> print_endline "cpp.objc.Protocol must refer to an interface";
					// 													die "" __LOC__;
					// 						)
					// | (["cpp"],"Struct"), [param] ->
					// 						TCppStruct(cpp_type_of stack ctx param)

					// | ([],"Array"), [p] ->
					// 			let arrayOf = cpp_type_of stack ctx p in
					// 			(match arrayOf with
					// 						| TCppVoid (* ? *)
					// 						| TCppDynamic ->
					// 								TCppDynamicArray

					// 						| TCppObject
					// 						| TCppObjectPtr
					// 						| TCppReference _
					// 						| TCppStruct _
					// 						| TCppStar _
					// 						| TCppEnum _
					// 						| TCppInst _
					// 						| TCppInterface _
					// 						| TCppProtocol _
					// 						| TCppClass
					// 						| TCppDynamicArray
					// 						| TCppObjectArray _
					// 						| TCppScalarArray _
					// 									-> TCppObjectArray(arrayOf)
					// 						| _ ->
					// 								TCppScalarArray(arrayOf)
					// 			)

					// | ([],"Null"), [p] ->
					// 						cpp_type_of_null stack ctx p

					// trace('Unknown core type "${TypeTools.toString(type)}"');
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

	static function resolveType(ct: ComplexType, pos: Position): Type {
		// replace references of cpp.Void to our typedef CppVoid, this is to work around a bug in Context.resolveType
		ct = ComplexTypeMap.map(ct, ct -> switch ct {
			case TPath({pack: ['cpp'], name: 'Void'}): macro :HaxeCInterface.CppVoid;
			case TPath({pack: ['cpp'], name: 'ConstPointer', params: [TPType(tp)]}): macro :HaxeCInterface.CppConstPointer<$tp>;
			default: ct;
		});
		return try Context.resolveType(ct, pos) catch(e) {
			Context.warning('Error resolving type ${ComplexTypeTools.toString(ct)}: $e', pos);
			Context.resolveType(macro :Any, pos);
		}
	}

	static public final cKeywords: ReadOnlyArray<String> = ["auto", "double", "int", "struct", "break", "else", "long", "switch", "case", "enum", "register", "typedef", "char", "extern", "return", "union", "const", "float", "short", "unsigned", "continue", "for", "signed", "void", "default", "goto", "sizeof", "volatile", "do", "if", "static", "while"];

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

#else

// these types exists to workaround bug with using cpp.Void directly in Context.resolveType
// maybe it's the `extern`?

@:native("void")
@:coreType
@:remove
@:noCompletion
abstract CppVoid {}

@:coreType
@:remove
@:noCompletion
abstract CppConstPointer<T> {}

#end