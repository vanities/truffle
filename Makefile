SCHEME   = Truffle
PROJECT  = Truffle.xcodeproj
SIM_FILE = build/.sim-udid
SIM     ?= $(shell cat $(SIM_FILE) 2>/dev/null)
DEST     = id=$(SIM)
APP      = build/DerivedData/Build/Products/Debug-iphonesimulator/Truffle.app

.PHONY: gen sim build test lint icon demo-library demo-server demo clean

gen:            ## Regenerate Truffle.xcodeproj from project.yml
	xcodegen generate

sim:            ## Create the dedicated "Truffle" simulator (iPhone 18 Pro, iOS 27.2) once
	@test -s $(SIM_FILE) || (mkdir -p build && xcrun simctl create "Truffle" "iPhone 18 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-2 > $(SIM_FILE))
	@cat $(SIM_FILE)

build: gen sim  ## Build for the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -derivedDataPath build/DerivedData build | tail -5

test: gen sim   ## Unit tests on the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -derivedDataPath build/DerivedData test | tail -20

lint:           ## SwiftLint
	swiftlint lint --quiet

icon:           ## Re-render the app icon
	swift scripts/render-icon.swift Truffle/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

demo-library:   ## Draw the demo covers (the server makes the audio on first start)
	swift scripts/make-demo-covers.swift scripts/demo-catalog.json demo-library

demo-server:    ## Stand-in Plex server on :32499
	scripts/demo_server.py

demo: build     ## Install and launch against the demo server
	xcrun simctl boot $(SIM) 2>/dev/null || true
	xcrun simctl install $(SIM) $(APP)
	xcrun simctl launch --terminate-running-process $(SIM) com.vanities.truffle -TruffleServerURL http://127.0.0.1:32499 -TruffleServerToken demo

clean:
	rm -rf build/DerivedData build/DerivedData-device
