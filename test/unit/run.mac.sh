# assumes macOS system
TIMEOUT_SECONDS=120

# https://gist.github.com/jaytaylor/6527607
function timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

make -f Makefile.mac clean
make -f Makefile.mac && {
	timeout $TIMEOUT_SECONDS ./app
}