import sys.FileSystem;
import haxe.macro.Type;
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.ComplexTypeTools;
import haxe.macro.TypeTools;
import haxe.macro.Printer;
import haxe.macro.Context;
import haxe.macro.Expr;

using Lambda;
using StringTools;

class HaxeCInterface {

	#if macro
	static final isDisplay = Context.defined('display') || Context.defined('display-details');
	static final noOutput = Sys.args().has('--no-output');
	
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

				// debug
				// var p = new Printer();
				// trace(p.printField(threadSafeFunction));
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
		if (!noOutput ||  true) {
			Context.onAfterGenerate(() -> {
				var outputDirectory = getOutputDirectory(); 
				touchDirectoryPath(outputDirectory);

				var projectName = determineProjectName();

				var header = generateHeader(projectName);
				var headerPath = Path.join([outputDirectory, '$projectName.h']);
				sys.io.File.saveContent(headerPath, header);
			});
		}

		isOnAfterGenerateSetup = true;
	}

	static function generateHeader(namespace: String) {
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
							signature: genCFunctionSignature('${typeNamespace}_${field.name}', fun)
						});
					case kind:
						throw 'Unsupported field kind "$kind"';
				}
			}
		}

		return part('
			/* $namespace.h */

			#ifndef ${namespace}_h
			#define ${namespace}_h

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
				char* ${namespace}_startHaxeThread(HaxeExceptionCallback fatalExceptionCallback);

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

		+ cFunSignatures.map(s ->
			part('
				${s.doc != null ? '/** ${s.doc} **/' : ''}
				${s.signature}
			')
		).join('\n')

		+ part('

			#ifdef __cplusplus
			}
			#endif

			#endif /* ${namespace}_h */
		');
	}

	static function genCFunctionSignature(name: String, hxFun: Function) {
		var cArgList = hxFun.args.map(arg -> '${genCType(arg.type)} ${arg.name}');
		return '${genCType(hxFun.ret)} $name(${cArgList.join(', ')});';
	}

	static function genCType(ct: ComplexType) {
		return 'void*';
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

	static function part(str: String) {
		return removeIndentation(str);
	}

	/**
		Remove common indentation from lines in a string
	**/
	static function removeIndentation(str: String) {
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

	static function getOutputDirectory() {
		var directoryTargets = [ 'as3', 'php', 'cpp', 'cs', 'java' ];
		return directoryTargets.has(Context.definedValue('target.name')) ? Compiler.getOutput() : Path.directory(Compiler.getOutput());
	}

	static final _voidType = Context.getType('Void');
	static function isVoid(ct: ComplexType) {
		return Context.unify(ComplexTypeTools.toType(ct), _voidType);
	}
	#end

}