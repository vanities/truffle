SCHEME   = Truffle
PROJECT  = Truffle.xcodeproj
SIM_FILE = build/.sim-udid
SIM     ?= $(shell cat $(SIM_FILE) 2>/dev/null)
DEST     = id=$(SIM)
APP      = build/DerivedData/Build/Products/Debug-iphonesimulator/Truffle.app

.PHONY: gen sim build test a11y-sim a11y lint icon demo-library demo-server demo clean

gen:            ## Regenerate Truffle.xcodeproj from project.yml
	xcodegen generate

sim:            ## Create the dedicated "Truffle" simulator (iPhone 18 Pro, iOS 27.2) once
	@test -s $(SIM_FILE) || (mkdir -p build && xcrun simctl create "Truffle" "iPhone 18 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-2 > $(SIM_FILE))
	@cat $(SIM_FILE)

build: gen sim  ## Build for the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -derivedDataPath build/DerivedData build | tail -5

test: gen sim   ## Unit tests on the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -derivedDataPath build/DerivedData test | tail -20

# The audit gets its own simulator: it signs in to the demo, and the "Truffle" one is signed in to a real server.
A11Y_SIM_FILE = build/.a11y-sim-udid
A11Y = xcodebuild -project $(PROJECT) -scheme TruffleAccessibility -destination id=$$(cat $(A11Y_SIM_FILE)) -derivedDataPath build/DerivedData

a11y-sim:       ## Create the "Truffle A11y" simulator the audit runs on
	@test -s $(A11Y_SIM_FILE) || (mkdir -p build && xcrun simctl create "Truffle A11y" "iPhone 18 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-2 > $(A11Y_SIM_FILE))
	@xcrun simctl boot $$(cat $(A11Y_SIM_FILE)) 2>/dev/null || true

a11y: gen a11y-sim ## Accessibility audit of every screen: light and dark, Increase Contrast off and on (about 25 min)
	$(A11Y) build-for-testing | tail -1
	@failed=0; for run in light,disabled,both dark,disabled,default light,enabled,default dark,enabled,default; do \
	  look=$${run%%,*}; rest=$${run#*,}; contrast=$${rest%%,*}; sizes=$${rest#*,}; \
	  echo "[a11y] $$look, Increase Contrast $$contrast, text sizes: $$sizes (build/a11y-$$look-$$contrast.log)"; \
	  xcrun simctl ui $$(cat $(A11Y_SIM_FILE)) appearance $$look; \
	  xcrun simctl ui $$(cat $(A11Y_SIM_FILE)) increase_contrast $$contrast; \
	  TEST_RUNNER_TRUFFLE_SIZES=$$sizes $(A11Y) test-without-building > build/a11y-$$look-$$contrast.log 2>&1 || failed=1; \
	  grep -E '^\[a11y\].*finding' build/a11y-$$look-$$contrast.log; \
	done; xcrun simctl ui $$(cat $(A11Y_SIM_FILE)) increase_contrast disabled; exit $$failed

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

# ---------------------------------------------------------------------------
# TestFlight, as Earmark does it. .env.appstore-connect (gitignored) holds the App Store Connect
# key; `upload` deliberately uses the Apple ID signed into Xcode instead (the key can't cloud-sign).
# ---------------------------------------------------------------------------
-include .env.appstore-connect
export
ARCHIVE = build/Truffle.xcarchive
ASC_AUTH = $(if $(APPSTORE_CONNECT_KEY_ID),-authenticationKeyPath "$(APPSTORE_CONNECT_KEY_FILE)" -authenticationKeyID "$(APPSTORE_CONNECT_KEY_ID)" -authenticationKeyIssuerID "$(APPSTORE_CONNECT_ISSUER_ID)",)

archive: gen    ## Release archive for iOS devices
	xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -archivePath $(ARCHIVE) -allowProvisioningUpdates $(ASC_AUTH) | tail -5

# System PATH only: Xcode's IPA step runs Apple's rsync with -E, which breaks if Homebrew's rsync is found first.
upload:         ## Sign for App Store Connect and upload the archive (TestFlight)
	PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist ExportOptions.plist \
	  -exportPath build/export -allowProvisioningUpdates | tail -5

testflight: archive upload ## Archive + upload
	@echo "Uploaded. Processing takes a few minutes; then: uv run --script scripts/testflight.py status"
