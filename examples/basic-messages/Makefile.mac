EXE=main
HAXE_BIN=haxe-bin
HAXE_LIB=HaxeProgram-debug.dylib

CC=clang
CFLAGS=-Wall $(HAXE_BIN)/$(HAXE_LIB)

all: $(HAXE_BIN)/$(HAXE_LIB) $(EXE)
# tell $(EXE) where the dynamic library is located
# more information: https://stackoverflow.com/questions/27506450/clang-change-dependent-shared-library-install-name-at-link-time
	install_name_tool -change $(HAXE_LIB) $(HAXE_BIN)/$(HAXE_LIB) $(EXE)

$(HAXE_BIN)/$(HAXE_LIB): ALWAYS_RUN
	haxe build.hxml

ALWAYS_RUN: ;

clean:
	rm -rf $(EXE) $(HAXE_BIN)

run: all
	./$(EXE)