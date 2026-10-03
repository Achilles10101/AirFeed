PKGS = sdl3 libavcodec libavutil srt
# Homebrew on this Mac has no pkg-config, so fall back to its fixed paths.
CFLAGS += -O2 -Wall $(shell pkg-config --cflags $(PKGS) 2>/dev/null || echo -I/opt/homebrew/include)
LDLIBS += $(shell pkg-config --libs $(PKGS) 2>/dev/null || echo -L/opt/homebrew/lib -lSDL3 -lavcodec -lavutil -lsrt)
ifeq ($(OS),Windows_NT)
# SDL's pkg-config asks for a windowed program, which has no console and so no status
# lines. The receiver needs its console.
LDLIBS := $(filter-out -mwindows,$(LDLIBS)) -lws2_32 -mconsole
endif

airfeed: airfeed.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

test: airfeed
	./test.sh

.PHONY: test
