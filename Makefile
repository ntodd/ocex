.PHONY: check test docs package package-smoke sanitize stress

check:
	mix format --check-formatted
	mix compile --warnings-as-errors
	mix test

test:
	mix test

docs:
	mix run scripts/check-api.exs
	mix run scripts/check-guides.exs
	mix docs --warnings-as-errors

package:
	mix hex.build

package-smoke:
	sh scripts/package-smoke.sh

sanitize:
	OCEX_SANITIZE=1 ERL_FLAGS='+S 1:1 +SDcpu 2' mix test

stress:
	mix run scripts/stress.exs
