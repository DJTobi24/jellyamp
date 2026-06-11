SWIFT_IMAGE ?= swift:6.0
SWIFT_DOCKER = docker run --rm -v $(CURDIR):/work -w /work $(SWIFT_IMAGE)

.PHONY: test-core test-server lint server-up server-down

test-core:
	$(SWIFT_DOCKER) bash -c "cd ios/Packages/JellyampCore && swift test"
	$(SWIFT_DOCKER) bash -c "cd ios/Packages/SonicClient && swift test"
	$(SWIFT_DOCKER) bash -c "cd ios/Packages/JellyfinBackend && swift test"

test-server:
	cd server && python3 -m pytest -q

lint:
	cd server && python3 -m ruff check .

server-up:
	cd server && docker compose up -d --build

server-down:
	cd server && docker compose down
