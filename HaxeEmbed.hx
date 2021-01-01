#if !macro
import cpp.Star;
import cpp.Callable;
import cpp.ConstCharStar;
import sys.thread.Lock;
import sys.thread.Thread;
import sys.thread.Mutex;

/**
 * Interface with a multi-threaded haxe program from C via message passing
 * 
 * **Requires haxe 4.2**
 *
 * ## Usage
 * In your haxe `main()`, call `HaxeEmbed.setMessageHandler(your-handler-function)` to receive messages from native code
 * 
 * In your native C code, include `include/HaxeEmbed.h` from the hxcpp generated code and call:
 * - `HaxeEmbed_startHaxeThread(exceptionCallback)` to start the haxe thread
 * - `HaxeEmbed_sendMessageSync(type, data)` to queue a message on the haxe thread and block until it is handled
 * - `HaxeEmbed_sendMessageAsync(type, data, onComplete)` to queue a message on the haxe thread, return immediately and execute the callback when the message has been handled
 * - `HaxeEmbed_stopHaxeThread()` to end the haxe thread (all state from the haxe thread is lost)
 *
 * @author haxiomic (George Corney)
**/

#if (!display && !display_details)

// expose this classes methods to be easily called externally
@:nativeGen
@:keep

// to expose a C-API we add to the compilation a little C-wrapper for this class
@:build(HaxeEmbed.Macro.hxcppAddNativeCode('./HaxeEmbed.h', 'HaxeEmbed.cpp'))
@:native('_HaxeEmbedGenerated')
#end
class HaxeEmbed {

	// ## Haxe Facing Interface ## //

	/**
		Set the function to be called when a message is sent from native code via one of the sendMessage* functions
	**/
	@:remove
	static public inline function setMessageHandler(onMessage: (type: String, data: Dynamic) -> Star<cpp.Void>) {
		Internal.messageHandler = onMessage;
	}

	// ## Native Facing Interface ## //

	/**
		Executes message handler with `type` and `data` on the haxe main thread and waits for handler completion

		Called from a foreign (but hxcpp-attached) thread
	**/
	@:noCompletion
	static public function sendMessageSync(type: String, data: Star<cpp.Void>): Star<cpp.Void> {
		if (Thread.current() == Internal.haxeMainThread) {
			return Internal.messageHandler(type, data);
		} else {
			Internal.sendMessageMutex.acquire();

			// queue message handler to run on the haxe main thread and wait for completion
			Internal.currentMessageType = type;
			Internal.currentMessageData = data;
			Internal.haxeMainThread.events.run(Internal.runEvent);

			// wait for runEvent() to complete
			Internal.runEventLock.wait();

			Internal.sendMessageMutex.release();

			return Internal.currentMessageResult;
		}
	}

	/**
		Executes message handler with `type` and `data` on the haxe main thread but does not wait for handler completion

		Because the message can be handled at an indeterminate time in the future, the caller must ensure the data pointer remains valid until then

		Called from a foreign (but hxcpp-attached) thread
	**/
	@:noCompletion
	static public function sendMessageAsync(type: String, data: Star<cpp.Void>, onComplete: Callable<(data: Star<cpp.Void>) -> Void>): Void {
		// queue message handler to run on the haxe main thread but don't wait for completion
		Internal.haxeMainThread.events.run(() -> {
			Internal.messageHandler(type, data);
			if (onComplete != null) {
				onComplete(data);
			}
		});
	}
	
	// ## Internal ## //
	
	/**
		Called after the main haxe thread has been initialized, but before main() and before the thread's event loop is initialized
	**/
	@:noCompletion
	static public function mainThreadInitialization() {
		Internal.haxeMainThread = Thread.current();
	}

	/**
		Keeps the main thread event loop alive (event after all events and promises are exhausted)
	**/
	@:noCompletion
	static public function mainThreadEndlessLoop() {
		while (true) {
			Internal.haxeMainThread.events.loop();
			Internal.haxeMainThread.events.wait();
		}
	}

	/**
		Break out of the event loop by throwing an end-thread exception
	**/
	@:noCompletion
	static public function mainThreadEnd() {
		Internal.haxeMainThread.events.run(() -> {
			throw new EndThreadException('END-THREAD');
		});
	}

}

private class EndThreadException extends haxe.Exception {}

/**
	We have to use a separate class to store data because `@:nativeGen` doesn't allow for variables.

	(If the `@:nativeGen`'d class is added to __boot__.cpp to initialize fields, it will be incorrectly referenced)
**/
private class Internal {

	static public var haxeMainThread: Thread;
	static public var messageHandler: (type: String, data: Dynamic) -> Star<cpp.Void> = defaultHandler;

	static public final sendMessageMutex = new Mutex();
	static public final runEventLock = new Lock();
	static public var currentMessageType: String;
	static public var currentMessageData: Star<cpp.Void>;
	static public var currentMessageResult: Star<cpp.Void>;
	static public function runEvent() {
		try {
			currentMessageResult = messageHandler(currentMessageType, currentMessageData);
			runEventLock.release();
		} catch(e: Any) {
			currentMessageResult = null;
			runEventLock.release();
			throw e;
		}
	}

	static function defaultHandler(type, _) {
		trace('Warning: received an event "$type" from native code but no handler has been set – call HaxeEmbed.setMessageHandler(handler) from your haxe main()');
		return null;
	}

}

#else

import haxe.macro.Context;
import haxe.io.Path;

class Macro {

	/**
		Adds :buildXml metadata that copies native interface code into the hxcpp output directory
	**/
	static function hxcppAddNativeCode(headerFilePath: String, implementationFilePath: String) {
		var classDir = getPosDirectory(Context.currentPos());

		var buildXml = '
			<copy from="$classDir/$headerFilePath" to="include" />

			<files id="haxe">
				<file name="$classDir/$implementationFilePath">
					<depend name="$classDir/$headerFilePath"/>
				</file>
			</files>
		';

		// add @:buildXml
		Context.getLocalClass().get().meta.add(':buildXml', [macro $v{buildXml}], Context.currentPos());

		return Context.getBuildFields();
	}

	/**
		Return the directory of the Context's current position

		For a @:build macro, this is the directory of the haxe file it's added to
	**/
	static public function getPosDirectory(pos: haxe.macro.Expr.Position) {
		var classPosInfo = Context.getPosInfos(pos);
		var classFilePath = Path.isAbsolute(classPosInfo.file) ? classPosInfo.file : Path.join([Sys.getCwd(), classPosInfo.file]);
		return Path.directory(classFilePath);
	}

}

#end