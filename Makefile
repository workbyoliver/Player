APP := build/Player.app
# Quit a running copy and wait for it to exit, so `open` launches the new build.
QUIT := pkill -x Player; while pgrep -x Player >/dev/null; do sleep 0.1; done

.PHONY: build debug run install zip clean

build:
	./scripts/build.sh

debug:
	CONFIG=debug ./scripts/build.sh

run: build
	$(QUIT)
	open $(APP)

install: build
	$(QUIT)
	rm -rf /Applications/Player.app
	cp -R $(APP) /Applications/Player.app
	open /Applications/Player.app

# dist/Player.zip to send to someone (see Caveats in README.md)
zip: build
	mkdir -p dist
	rm -f dist/Player.zip
	ditto -c -k --keepParent $(APP) dist/Player.zip

clean:
	rm -rf build .build dist
