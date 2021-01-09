#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>

#include "haxe-bin/MessagePayload.h"
#include "haxe-bin/HaxeLib.h"

#define log(fmt) printf("%s:%d: " fmt, __FILE__, __LINE__);
#define logv(fmt, ...) printf("%s:%d: " fmt, __FILE__, __LINE__, __VA_ARGS__);

// called from the haxe main thread
// the thread will continue running
void onHaxeException(const char* info) {
	logv("Uncaught haxe exception (manually stopping haxe thread): %s\n", info);
	HaxeLib_stopHaxeThread();
	log("thread stopped\n");
}

// we pass this to our haxe program via setMessageSync to test calling into native code from haxe
// it will be called on the haxe thread
void nativeCallback(int number) {
	logv("native callback %d\n", number);
}

int main(void) {
	log("Hello From C\n");

	HaxeLib_stopHaxeThread();
	
	const char* result = HaxeLib_initializeHaxeThread(onHaxeException);
	if (result != NULL) {
		logv("Failed to initialize haxe: %s\n", result);
	}
	assert(result == NULL);

	assert(HaxeLib_callInMainThread(123.4));
	assert(HaxeLib_callInExternalThread(567.8));
	assert(HaxeLib_add(3, 4) == 7);

	int i = 3;
	int* starI = &i;
	// changes value of i to length of string, returns pointer to i
	int* r = HaxeLib_starPointers((void*)starI, (void*)starI, (void*)&starI, &starI, (const void*) &i, &i, "string-length-16");
	assert(i == 16);
	assert(starI == r);

	HaxeLib_throwException();

	// end the haxe thread (this will block while the haxe thread finishes processing immediate pending events)
	log("Stopping haxe thread\n");
	HaxeLib_stopHaxeThread();

	// trying to reinitialize haxe thread should fail
	log("Starting haxe thread\n");
	result = HaxeLib_initializeHaxeThread(onHaxeException);
	assert(result != NULL);
	if (result != NULL) {
		logv("Failed to initialize haxe: %s\n", result);
	}
	log("Stopping haxe thread\n");
	HaxeLib_stopHaxeThread();

	return 0;
}
