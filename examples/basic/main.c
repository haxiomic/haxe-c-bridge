#include <stdio.h>
#include <unistd.h>
#include "haxe-bin/include/HaxeEmbed.h"

void onHaxeException(const char* info) {
	printf("main.c: Uncaught exception: %s\n", info);
}

void nativeCallback() {
	printf("main.c: native callback\n");
}

int main(void) {
	printf("main.c: Hello From C\n");
	
	const char* result = HaxeEmbed_initHaxeThread(onHaxeException);

	if (result != NULL) {
		printf("Failed to initialize haxe: %s", result);
	}

	HaxeEmbed_sendMessageSync("SET-NATIVE-CALLBACK", nativeCallback);

	int data = 42;
	void* reply = HaxeEmbed_sendMessageSync("NUMBER", &data);
	printf("main.c: reply from haxe '%s'\n", reply);

	// queue an async message and change data immediately after
	HaxeEmbed_sendMessageAsync("NUMBER", &data);
	data = 7;

	// sleep 3s
	printf("main.c: sleeping 3s\n");
	sleep(3);
	printf("main.c: sleep complete\n");

	HaxeEmbed_sendMessageAsync("TRIGGER-EXCEPTION", NULL);

	HaxeEmbed_endHaxeThread();
	printf("main.c: haxe thread ended\n");

	HaxeEmbed_initHaxeThread(onHaxeException);
	printf("main.c: haxe thread reinitialized\n");

	// sleep 3s
	printf("main.c: sleeping 3s\n");
	sleep(3);
	printf("main.c: sleep complete\n");

	HaxeEmbed_endHaxeThread();

	return 0;
}