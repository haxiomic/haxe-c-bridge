#include "haxe-bin/MessagePayload.h"
#include "haxe-bin/HaxeLib.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
#include <time.h>
#include <inttypes.h>
#include <stdbool.h>

#define log(str) printf("%s:%d: " str "\n", __FILE__, __LINE__)
#define logf(fmt, ...) printf("%s:%d: " fmt "\n", __FILE__, __LINE__, __VA_ARGS__)

// called from the haxe main thread
// the thread will continue running
void onHaxeException(const char* info) {
	logf("onHaxeException (manually stopping haxe thread): \"%s\"", info);
	HaxeLib_stopHaxeThread();
	log("-> thread stopped");
}

// we pass this to our haxe program via setMessageSync to test calling into native code from haxe
// it will be called on the haxe thread
void nativeCallback(int number) {
	logf("native callback %d", number);
}

void assertCallback(bool v) {
	assert(v);
}

// callback testing
void fnVoid() {}
int fnInt() {return 42;}
const char* fnIntString(int i) {
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
void fnStruct(MessagePayload msg) {
	assert(msg.someFloat == 42.0);
	assert(strcmp(msg.cStr, "hello") == 0);
}

int main(void) {
	log("Hello From C");
	
	// we can call stop without a haxe thread, but it should return false and do nothing
	assert(!HaxeLib_stopHaxeThread());
	
	log("Starting haxe thread");
	const char* result = HaxeLib_initializeHaxeThread(onHaxeException);
	if (result != NULL) {
		logf("Failed to initialize haxe: %s", result);
	}
	assert(result == NULL);

	log("Testing calls to haxe code");

	logf("GC Memory: %d", HaxeLib_Main_hxcppGcMemUsage());

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

	function_Int_cpp_ConstCharStar ret = HaxeLib_hxcppCallbacks(
		assertCallback,
		fnVoid,
		fnInt,
		fnIntString,
		fnPointers,
		fnIntStarStr,
		fnStruct
	);
	assert(ret == fnIntString);

	// struct
	MessagePayload inputStruct = {
		.someFloat = 24.0,
		.cStr = "hello"
	};
	MessagePayload retStruct = HaxeLib_externStruct(inputStruct, &inputStruct);
	assert(inputStruct.someFloat == 12.0);
	assert(retStruct.someFloat == 24.0 * 2);

	assert(HaxeLib_enumTypes(B, "AAA", AAA) == BBB);

	// sleep one second and verify the haxe thread event loop continued to run
	log("sleeping 1s to let the haxe thread event loop run");
	sleep(1);
	logf("-> HaxeLib_Main_getLoopCount() => %d", HaxeLib_Main_getLoopCount());
	assert(HaxeLib_Main_getLoopCount() > 2);

	// try loads of calls to haxe
	int64_t callCount = 1000 * 1000;
	logf("Trying %" PRId64 " calls into the haxe main thread to measure synchronization and memory costs ...", callCount);
	HaxeLib_Main_printTime();
	clock_t start = clock(), dt;
	for (int64_t i = 0; i < callCount; i++) {
		HaxeLib_noArgsNoReturn();
	}
	dt = clock() - start;
	int dt_ms = dt * 1000 / CLOCKS_PER_SEC;
	logf("-> total time: %d (ms)", dt_ms);
	logf("-> per call: %f (ms)", (double) dt_ms / (callCount));

	logf("GC Memory: %d", HaxeLib_Main_hxcppGcMemUsage());

	// test gc, ensure we have no issues with leaks
	log("Allocation a bunch of data in haxe");

	HaxeLib_allocateABunchOfData();
	HaxeLib_allocateABunchOfDataExternalThread();

	logf("GC Memory (before major collection): %d", HaxeLib_Main_hxcppGcMemUsage());
	log("Running major GC collection");
	HaxeLib_Main_hxcppGcRun(true);
	logf("GC Memory (after major collection): %d", HaxeLib_Main_hxcppGcMemUsage());
	logf("GC Memory: %d", HaxeLib_Main_hxcppGcMemUsage());

	// check unhandled exception callback fires
	log("Testing triggering exception in haxe"); // this is asynchronous
	HaxeLib_throwException();

	// end the haxe thread (this will block while the haxe thread finishes processing immediate pending events)
	log("Stopping haxe thread (manually)");
	HaxeLib_stopHaxeThread();

	// trying to reinitialize haxe thread should fail
	log("Starting haxe thread");
	result = HaxeLib_initializeHaxeThread(onHaxeException);
	assert(result != NULL);
	if (result != NULL) {
		logf("Failed to initialize haxe: %s", result);
	}
	log("Stopping haxe thread");
	HaxeLib_stopHaxeThread();

	log("All tests completed successfully");

	return 0;
}
