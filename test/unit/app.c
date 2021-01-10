#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>

#include "haxe-bin/MessagePayload.h"
#include "haxe-bin/HaxeLib.h"

#define log(str) printf("%s:%d: " str, __FILE__, __LINE__);
#define logf(fmt, ...) printf("%s:%d: " fmt, __FILE__, __LINE__, __VA_ARGS__);

// called from the haxe main thread
// the thread will continue running
void onHaxeException(const char* info) {
	logf("Uncaught haxe exception (manually stopping haxe thread): %s\n", info);
	HaxeLib_stopHaxeThread();
	log("thread stopped\n");
}

// we pass this to our haxe program via setMessageSync to test calling into native code from haxe
// it will be called on the haxe thread
void nativeCallback(int number) {
	logf("native callback %d\n", number);
}

void assertCallback(bool v) {
	assert(v);
}

// callback testing
void fnVoid() {}
int fnInt() {return 42;}
const char* fnIntString(int i) {
	logf("%d\n", i);
	assert(i == 42);
	static const char* str = "hi";
	return str;
}
int fnStringInt(const char* str) {
	return strlen(str);
}
int* fnPointers(int* i) {
	(*i)/=2;
	return i;
}
const char* fnIntStarStr(int* i) {
	return "ok";
}

int main(void) {
	log("Hello From C\n");

	HaxeLib_stopHaxeThread();
	
	const char* result = HaxeLib_initializeHaxeThread(onHaxeException);
	if (result != NULL) {
		logf("Failed to initialize haxe: %s\n", result);
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

	int64_t i64 = 12;
	assert(HaxeLib_rawPointers((void*)&i64, &i64, "hallo-world") == &i64);

	int64_t i64Array[3] = {1, 2, 3};
	assert(HaxeLib_hxcppPointers(assertCallback, (void*)&i64, i64Array, sizeof(i64Array)/sizeof(i64Array[0]), "hallo-world") == i64Array);

	function_Int_String ret = HaxeLib_hxcppCallbacks(
		assertCallback,
		fnVoid,
		fnInt,
		fnIntString,
		fnStringInt,
		fnPointers,
		fnIntStarStr
	);
	assert(ret == fnIntString);

	HaxeLib_throwException();

	// end the haxe thread (this will block while the haxe thread finishes processing immediate pending events)
	log("Stopping haxe thread\n");
	HaxeLib_stopHaxeThread();

	// trying to reinitialize haxe thread should fail
	log("Starting haxe thread\n");
	result = HaxeLib_initializeHaxeThread(onHaxeException);
	assert(result != NULL);
	if (result != NULL) {
		logf("Failed to initialize haxe: %s\n", result);
	}
	log("Stopping haxe thread\n");
	HaxeLib_stopHaxeThread();

	return 0;
}
