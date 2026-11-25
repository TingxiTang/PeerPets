SHELL := /bin/sh
SWIFTC := xcrun swiftc
CACHE := build/module-cache
SWIFT_SRC := tools/GlassDesk.swift tools/PeerPetsActivity.swift tools/PeerPets.swift
APP := build/PeerPets.app
MACOS := $(APP)/Contents/MacOS
RESOURCES := LICENSE macos/Resources/ART-CREDITS.txt macos/Resources/CrossPet-LICENSE.md \
             macos/Resources/gpt-idle.webp macos/Resources/gpt-thinking.webp \
             macos/Resources/gemini-idle.webp macos/Resources/gemini-thinking.webp

.PHONY: app test
app: $(APP)/Contents/_CodeSignature/CodeResources
	codesign --verify --strict "$(APP)"

$(APP)/Contents/_CodeSignature/CodeResources: build/PeerPets-arm64 build/PeerPets-x86_64 macos/Info.plist $(RESOURCES)
	mkdir -p "$(MACOS)" "$(APP)/Contents/Resources"
	xcrun lipo -create build/PeerPets-arm64 build/PeerPets-x86_64 -output "$(MACOS)/PeerPets"
	cp macos/Info.plist "$(APP)/Contents/"
	cp $(RESOURCES) "$(APP)/Contents/Resources/"
	codesign --force --sign - "$(APP)"

build/PeerPets-%: $(SWIFT_SRC)
	mkdir -p "$(CACHE)"
	$(SWIFTC) -module-cache-path "$(CACHE)" -O -target $*-apple-macosx13.0 $(SWIFT_SRC) -o "$@"

test:
	python3 -B -m unittest discover -s tools/tests
	mkdir -p "$(CACHE)"
	$(SWIFTC) -module-cache-path "$(CACHE)" tools/PeerPetsActivity.swift tools/tests/peer-pets/main.swift -o build/test-peer-pets
	./build/test-peer-pets

.PHONY: release
release: app
	python3 scripts/package.py
