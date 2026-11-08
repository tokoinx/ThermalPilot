.PHONY: all build app cli test run clean install

all: app

build:
	swift build -c release

app:
	./scripts/build-app.sh

cli:
	swift build -c release --product thermalctl
	@echo "→ $$(swift build -c release --show-bin-path)/thermalctl"

install:
	sudo ./scripts/install-cli.sh
	cp -R dist/ThermalPilot.app /Applications/

test:
	swift test

run:
	swift run ThermalPilot

clean:
	rm -rf .build dist
