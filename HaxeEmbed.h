/**
 * Interface with a multi-threaded haxe program from C via message passing
 * 
 * @author haxiomic (George Corney)
 */

#ifndef HaxeEmbedC_h
#define HaxeEmbedC_h

typedef void (* HaxeExceptionCallback) (const char* exceptionInfo);
typedef void (* HaxeMessageHandledCallback) (void* data);

#ifdef __cplusplus
extern "C" {
#endif

	/**
	 * Initializes a haxe thread that remains alive indefinitely and executes the user's haxe main()
	 * 
	 * This must be called before sending messages
	 * 
	 * It may be called again if `HaxeEmbed_stopHaxeThread` is used to end the current haxe thread first (all state from the previous execution will be lost)
	 * 
	 * Thread-safe
	 * 
	 * @param unhandledExceptionCallback a callback to exectue if a fatal unhandled exception occurs on the haxe thread. This will be executed on the haxe thread immediately before it ends. Use `NULL` for no callback
	 * @returns `NULL` if the thread initializes successfully or a null terminated C string with exception if an exception occurs during initialization
	 */
	const char* HaxeEmbed_startHaxeThread(HaxeExceptionCallback unhandledExceptionCallback);

	/**
	 * Ends the haxe thread after it finishes processing pending events (events scheduled in the future will not be executed)
	 * 
	 * Blocks until the haxe thread has finished
	 * 
	 * `HaxeEmbed_startHaxeThread` may be used to reinitialize the thread. Haxe main() will be called for a second time and all state from the previous execution will be lost
	 * 
	 * Thread-safety: May be called on a different thread to `HaxeEmbed_startHaxeThread` but must not be called from the haxe thread
	 */
	void HaxeEmbed_stopHaxeThread();

	/**
	 * Executes haxe message handler with `type` and `data` on the haxe main thread and waits for handler completion
	 * 
	 * Thread-safe
	 * 
	 * @param type C string to pass into the message handler as the message's type
	 * @param data pointer to pass in as the message handler as the message's data
	 * @returns Value returned from the haxe message handler (becarefull returning haxe objects that may be garbage collected). If a an unhandled exception occurs during handling, `NULL` will be returned and the haxe thread will end
	**/
	void* HaxeEmbed_sendMessageSync(const char* type, void* data);

	/**
	 * Executes haxe message handler with `type` and `data` on the haxe main thread but does not wait for handler completion
	 * 
	 * Because the message can be handled at an indeterminate time in the future, the caller must ensure the data pointer remains valid until then
	 * 
	 * Thread-safe
	 * 
	 * @param type C string to pass into the message handler as the message's type
	 * @param data pointer to pass in as the message handler as the message's data
	 * @param onComplete callback executed on the haxe thread after the message is handled – you may want to use this to free data allocated for this message (if you know it is no longer used). Use `NULL` for no callback
	**/
	void HaxeEmbed_sendMessageAsync(const char* type, void* data, HaxeMessageHandledCallback onComplete);

#ifdef __cplusplus
}
#endif

#endif /* HaxeEmbedC_h */