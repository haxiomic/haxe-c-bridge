#include "haxe-bin/MessagePayload.h"
#include "haxe-bin/HaxeLib.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <inttypes.h>
#include <stdbool.h>

#ifdef _WIN32
	// windows compatibility
	#include <windows.h>

	// time.h implementation https://stackoverflow.com/a/31335254
	struct timespec { long tv_sec; long tv_nsec; };   //header part
	#define exp7           10000000LL     //1E+7     //C-file part
	#define exp9         1000000000LL     //1E+9
	#define w2ux 116444736000000000LL     //1.jan1601 to 1.jan1970
	#define CLOCK_REALTIME 0
	
	void unix_time(struct timespec *spec)
	{  __int64 wintime; GetSystemTimeAsFileTime((FILETIME*)&wintime); 
	wintime -=w2ux;  spec->tv_sec  =wintime / exp7;                 
						spec->tv_nsec =wintime % exp7 *100;
	}

	int clock_gettime(int _, struct timespec *spec)
	{  static  struct timespec startspec; static double ticks2nano;
	static __int64 startticks, tps =0;    __int64 tmp, curticks;
	QueryPerformanceFrequency((LARGE_INTEGER*)&tmp); //some strange system can
	if (tps !=tmp) { tps =tmp; //init ~~ONCE         //possibly change freq ?
						QueryPerformanceCounter((LARGE_INTEGER*)&startticks);
						unix_time(&startspec); ticks2nano =(double)exp9 / tps; }
	QueryPerformanceCounter((LARGE_INTEGER*)&curticks); curticks -=startticks;
	spec->tv_sec  =startspec.tv_sec   +         (curticks / tps);
	spec->tv_nsec =startspec.tv_nsec  + (double)(curticks % tps) * ticks2nano;
			if (!(spec->tv_nsec < exp9)) { spec->tv_sec++; spec->tv_nsec -=exp9; }
	return 0;
	}
#else
	#include <time.h>
	#include <unistd.h>
#endif

#define log(str) printf("%s:%d: " str "\n", __FILE__, __LINE__)
#define logf(fmt, ...) printf("%s:%d: " fmt "\n", __FILE__, __LINE__, __VA_ARGS__)

// called from the haxe main thread
// the thread will continue running
void onHaxeException(const char* info) {
	logf("onHaxeException: \"%s\"", info);
	assert(strcmp(info, "example exception") == 0); // an exception with this string is expected (all others are unexpected!)
	HaxeLib_stopHaxeThreadIfRunning(true); // (in a real app, you'd want to use `false` here so the thread exits immediately, but here we let it wait for pending events to complete)
	log("-> thread stop requested (waitOnScheduledEvents = true)");
}

void assertCallback(bool v) {
	assert(v);
}

// callback testing
void fnVoid() {
	// check we can still call the exposed C methods while in the haxe thread
	assert(HaxeLib_add(3, 4) == 7);
}
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

double deltaTime_ns(struct timespec start, struct timespec end) {
	return (double)(end.tv_sec - start.tv_sec) * 1.0e9 + (double)(end.tv_nsec - start.tv_nsec);
}
double deltaTime_ms(struct timespec start, struct timespec end) {
	return deltaTime_ns(start, end) / 1e6;
}

int main(void) {
	log("Hello From C");
	
	// we can call stop without a haxe thread, but it should do nothing
	HaxeLib_stopHaxeThreadIfRunning(true);
	
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

	// enum
	assert(HaxeLib_enumTypes(B, "AAA", AAA) == BBB);

	// haxe objects and strings
	for (int i = 0; i < 100; i++) {
		// // run a major GC to make sure obj would be collected if not protected
		HaxeLib_Main_hxcppGcRun(true);
		HaxeObject obj = HaxeLib_createHaxeAnon();
		HaxeLib_checkHaxeAnon(obj);
		HaxeLib_checkAnonFromPointer(obj);
		HaxeLib_releaseHaxeObject(obj);

		const char* haxeStr = HaxeLib_createHaxeString();
		HaxeLib_checkHaxeString(haxeStr);
		HaxeLib_releaseHaxeString(haxeStr);

		HaxeObject map = HaxeLib_createHaxeMap();
		HaxeLib_checkHaxeMap(map);
		HaxeLib_releaseHaxeObject(map);

		HaxeObject c = HaxeLib_createCustomType();
		HaxeLib_checkCustomType(c);
		HaxeLib_releaseHaxeObject(c);

		// instance test
		HaxeObject* instance = HaxeLib_Instance_new("new from C");
		HaxeLib_Instance_methodNoArgs(instance);
		assert(HaxeLib_Instance_methodAdd(instance, 5, 6) == 11);
		HaxeString s = HaxeLib_Instance_overrideMe(instance);
		assert(strcmp(s, "new from C") == 0);
		HaxeLib_releaseHaxeString(s);
		HaxeLib_releaseHaxeObject(instance);

		#ifdef VALIDATE_RETAIN_CRASH
		// To validate haxe object release worked, uncomment this with ASan enabled; should crash :)
		HaxeLib_add(1,1); // < executing another call on the main thread first ensures the call to release executed (as that call is async)
		HaxeLib_Main_hxcppGcRun(true);
		HaxeLib_checkHaxeString(haxeStr); // expected to throw an exception because the string now contains junk
		HaxeLib_checkHaxeObject(obj); // expected to trigger asan crash
		HaxeLib_checkHaxeMap(map);
		HaxeLib_Instance_methodNoArgs(instance); // asan crash
		#endif
	}

	// can we pass NULL for an object?
	HaxeLib_checkNull(NULL, 0);

	for (int i = 0; i < 100; i++) { // run many times to try to catch GC issues
		// test returning Array<Int>
		int arrayLength = 0;
		int* array = HaxeLib_getHaxeArray(&arrayLength);
		// run a major GC to make sure the underlying data would be collected if there was a bug
		HaxeLib_Main_hxcppGcRun(true);
		// expect [1,2,3,4,5]
		assert(arrayLength == 5);
		if (array[0] != 1 || array[1] != 2 || array[2] != 3 || array[3] != 4 || array[4] != 5) {
			logf("Array<int> (%d), expected [1, 2, 3, 4, 5] got [%d, %d, %d, %d, %d]", arrayLength, array[0], array[1], array[2], array[3], array[4]);
			assert(false);
		}
	}
	{
		int arrayLength = 0;
		const char** array = (const char**)HaxeLib_getHaxeArrayStr(&arrayLength);
		// run a major GC to make sure the underlying data would be collected if there was a bug
		HaxeLib_Main_hxcppGcRun(true);
		assert(arrayLength == 3);
		logf("array char* (%d) [%s, %s, %s]", arrayLength, array[0], array[1], array[2]);
	}

	// sleep one second and verify the haxe thread event loop continued to run
	log("sleeping 1s to let the haxe thread event loop run");
	#ifdef _WIN32
	Sleep(1000);
	#else
	sleep(1);
	#endif
	logf("-> HaxeLib_Main_getLoopCount() => %d", HaxeLib_Main_getLoopCount());
	assert(HaxeLib_Main_getLoopCount() > 2);

	// try loads of calls to haxe
	int64_t callCount = 1000 * 1000;
	logf("Trying %" PRId64 " calls into the haxe main thread to measure synchronization and memory costs ...", callCount);
	{
		struct timespec start;
		struct timespec end;
		HaxeLib_Main_printTime();
		clock_gettime(CLOCK_REALTIME, &start);
		for (int64_t i = 0; i < callCount; i++) {
			HaxeNoArgsNoReturn();
		}
		clock_gettime(CLOCK_REALTIME, &end);
		HaxeLib_Main_printTime();
		int dt_ms = deltaTime_ms(start, end);
		logf("-> total time: %d (ms)", dt_ms);
		logf("-> per call: %f (ms)", (double) dt_ms / (callCount));
	}

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

	// if we don't call this then the infinite haxe.Timer loop will keep the main thread alive
	// (unless we use `HaxeLib_stopHaxeThreadIfRunning(false)`)
	HaxeLib_Main_stopLoopingAfterTime_ms(1000);

	// check unhandled exception callback fires
	log("Testing triggering exception in haxe"); // this is asynchronous
	HaxeLib_throwException();

	// end the haxe thread (this will block while the haxe thread finishes processing immediate pending events)
	struct timespec start;
	struct timespec end;
	clock_gettime(CLOCK_REALTIME, &start);
	log("Stopping haxe thread and waiting for pending events to complete");
	HaxeLib_stopHaxeThreadIfRunning(true);
	clock_gettime(CLOCK_REALTIME, &end);
	// because waitOnScheduledEvents == true we expect stop haxe thread to block until the looping has stopped (which we scheduled 1s in the future)
	// (whereas if waitOnScheduledEvents == false we expect to stop to be nearly immediate)
	assert(deltaTime_ms(start, end) >= 500);

	// trying to reinitialize haxe thread should fail
	log("Starting haxe thread");
	result = HaxeLib_initializeHaxeThread(onHaxeException);
	assert(result != NULL);
	if (result != NULL) {
		logf("Expect no initializing twice error: \"%s\"", result);
	}
	log("Testing stopping haxe thread a second time (despite it not currently running)");
	HaxeLib_stopHaxeThreadIfRunning(true);

	log("All tests completed successfully");

	return 0;
}
