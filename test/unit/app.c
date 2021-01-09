#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>

#include "haxe-bin/MessagePayload.h"
#include "haxe-bin/HaxeLib.h"

// called from the haxe main thread before it terminates after an unhandled exception
void onHaxeException(const char* info) {
	printf("app.c: Uncaught haxe exception: %s\n", info);
}

// we pass this to our haxe program via setMessageSync to test calling into native code from haxe
// it will be called on the haxe thread
void nativeCallback(int number) {
	printf("app.c: native callback %d\n", number);
}

int main(void) {
	printf("app.c: Hello From C\n");
	
	const char* result = HaxeLib_startHaxeThread(onHaxeException);

	if (result != NULL) {
		printf("Failed to initialize haxe: %s", result);
	}

	assert(HaxeLib_callInMainThread(123.4));
	assert(HaxeLib_callInExternalThread(567.8));
	assert(HaxeLib_add(3, 4) == 7);

	int i = 3;
	int* starI = &i;
	// changes value of i to length of string, returns pointer to i
	int* r = HaxeLib_starPointers((void*)starI, (void*)starI, (void*)&starI, &starI, (const void*) &i, &i, "string-length-16");
	assert(i == 16);
	assert(starI == r);

	sleep(3);

	// end the haxe thread (this will block while the haxe thread finishes processing immediate pending events)
	HaxeLib_stopHaxeThread();

	return 0;
}
