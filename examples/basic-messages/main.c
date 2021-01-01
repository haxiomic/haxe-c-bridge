#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "MessagePayload.h"
#include "haxe-bin/include/HaxeEmbed.h"

// called from the haxe main thread before it terminates after an unhandled exception
void onHaxeException(const char* info) {
	printf("main.c: Uncaught haxe exception: %s\n", info);
}

// we pass this to our haxe program via setMessageSync to test calling into native code from haxe
// it will be called on the haxe thread
void nativeCallback(int number) {
	printf("main.c: native callback %d\n", number);
}

int main(void) {
	printf("main.c: Hello From C\n");
	
	const char* result = HaxeEmbed_startHaxeThread(onHaxeException);

	if (result != NULL) {
		printf("Failed to initialize haxe: %s", result);
	}

	HaxeEmbed_sendMessageSync("SET-NATIVE-CALLBACK", nativeCallback);

	int data = 42;
	void* reply = HaxeEmbed_sendMessageSync("NUMBER", &data);
	printf("main.c: message reply from haxe '%s' (%p)\n", reply, reply);

	// queue an async message and change data immediately after
	HaxeEmbed_sendMessageAsync("NUMBER", &data, NULL);
	// this is multi-threaded evilness (and undefined behavior), but demonstrates that the message is handled asynchronously by the haxe thread
	// the value of number will depend on what executes first, data = 7 or the haxe thread processing the message (where number will still be 42)
	data = 7;

	// queue an async message with data allocated with malloc
	// we can use the onComplete callback to free our allocated data now we know it's no longer needed
	MessagePayload* payload = (MessagePayload*) malloc(sizeof(MessagePayload));
	payload->someFloat = 123.456;
	strcpy(payload->cStr, "hello\0");

	HaxeEmbed_sendMessageAsync("ASYNC-MESSAGE", payload, free);

	// sleep 3s while the haxe thread continues
	printf("main.c: sleeping 3s\n");
	sleep(3);
	printf("main.c: sleep complete\n");

	// test triggering an unhandled exception (this should execute our exception callback)
	HaxeEmbed_sendMessageAsync("TRIGGER-EXCEPTION", NULL, NULL);

	HaxeEmbed_endHaxeThread();
	printf("main.c: haxe thread ended\n");

	// start the haxe thread again, all data stored in static variables in haxe will be lost
	HaxeEmbed_startHaxeThread(onHaxeException);
	printf("main.c: haxe thread reinitialized\n");

	// sleep 3s while the haxe thread continues
	printf("main.c: sleeping 3s\n");
	sleep(3);
	printf("main.c: sleep complete\n");

	// end the haxe thread (this will block while the haxe thread finishes processing immediate pending events)
	HaxeEmbed_endHaxeThread();

	return 0;
}