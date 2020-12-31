/**
 * C language wrapper to interact with HaxeEmbed from C
 * 
 * @author haxiomic (George Corney)
 */

#ifndef HaxeEmbedC_h
#define HaxeEmbedC_h

typedef void (* HaxeExceptionCallback) (const char* exceptionInfo);

#ifdef __cplusplus
extern "C" {
#endif

	/**
	 * Initializes a haxe thread that remains alive indefinitely and executes the user's haxe main()
	 * 
	 * This must be called before sending messages
	 * 
	 * It may be called again if `HaxeEmbed_endHaxeThread` is used to end the current haxe thread (all values stored in static variables in haxe will be lose)
	 * 
	 * @param unhandledExceptionCallback a callback to exectue if a fatal unhandled exception occurs on the haxe thread. This will be executed on the haxe thread immediately before it ends. Use `NULL` for no callback
	 * @returns `NULL` if the thread initializes successfully or a null terminated C string with exception if an exception occurs during initialization
	 */
	const char* HaxeEmbed_initHaxeThread(HaxeExceptionCallback unhandledExceptionCallback);

	/**
	 * Ends the haxe thread after it finishes processing pending events (events scheduled in the future will not be executed)
	 * 
	 * Blocks until the haxe thread has finished
	 * 
	 * `HaxeEmbed_initHaxeThread` may be used to reinitialize the thread (haxe main() will be called for a second time)
	 */
	void HaxeEmbed_endHaxeThread();

	/**
	 * Executes haxe message handler with `type` and `data` on the haxe main thread and waits for handler completion
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
	 * @param type C string to pass into the message handler as the message's type
	 * @param data pointer to pass in as the message handler as the message's data
	**/
	void  HaxeEmbed_sendMessageAsync(const char* type, void* data);

#ifdef __cplusplus
}
#endif

#endif /* HaxeEmbedC_h */