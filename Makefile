.PHONY: app run smoke-test test

app:
	@/bin/sh Scripts/build-app.sh

run:
	@/bin/sh Scripts/run-app.sh

smoke-test:
	@/bin/sh Scripts/smoke-test-app.sh

test:
	@swift test
