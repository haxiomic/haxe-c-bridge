/**
 * Impelement starting and ending the haxe thread and pass through sendMessage* calls
 * 
 * @author haxiomic (George Corney)
 */
#include <hxcpp.h>
#include <hx/Native.h>
#include <hx/Thread.h>

#include "HaxeEmbed.h"

// hxcpp-generated C++ header for HaxeEmbed.hx
#include "_HaxeEmbedGenerated.h"

#include "_HaxeEmbed/EndThreadException.h"

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

		_HaxeEmbedGenerated::mainThreadInitialization();

	} catch(Dynamic initException) {
		
		// hxcpp init failure or uncaught haxe runtime exception
		HX_TOP_OF_STACK
		threadInitExceptionInfo = initException->toString().utf8_str();

	}

	threadInitSemaphore.Set();

	try {

		// this will block until all pending events created from main() have completed
		__hxcpp_main();

		// we want to keep alive the thread after main() has completed, so we run the event loop until we want to terminate the thread
		_HaxeEmbedGenerated::mainThreadEndlessLoop();

	} catch(Dynamic runtimeException) {

		// An EndThreadException is used to break out of the event loop, we don't need to report this exception
		if (!runtimeException.IsClass<_HaxeEmbed::EndThreadException>()) {
			if (haxeExceptionCallback != nullptr) {
				const char* info = runtimeException->toString().utf8_str();
				haxeExceptionCallback(info);
			}
		}

	}

	threadEndSemaphore.Set();

	THREAD_FUNC_RET
}

HXCPP_EXTERN_CLASS_ATTRIBUTES
const char* HaxeEmbed_startHaxeThread(HaxeExceptionCallback unhandledExceptionCallback) {
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
void HaxeEmbed_stopHaxeThread() {
	threadManageMutex.Lock();

	if (!threadInitialized) return;

	hx::NativeAttach autoAttach;

	// queue an exception into the event loop so we break out of the loop and end the thread
	_HaxeEmbedGenerated::mainThreadEnd();

	// block until the thread ends, the haxe thread will first exectue all immediately pending events
	threadEndSemaphore.Wait();

	threadInitialized = false;

	threadManageMutex.Unlock();
}

HXCPP_EXTERN_CLASS_ATTRIBUTES
void* HaxeEmbed_sendMessageSync(const char* type, void* data) {
	hx::NativeAttach autoAttach;
	return _HaxeEmbedGenerated::sendMessageSync(type, data);
}

HXCPP_EXTERN_CLASS_ATTRIBUTES
void HaxeEmbed_sendMessageAsync(const char* type, void* data, HaxeMessageHandledCallback onComplete) {
	hx::NativeAttach autoAttach;
	_HaxeEmbedGenerated::sendMessageAsync(type, data, onComplete);
}