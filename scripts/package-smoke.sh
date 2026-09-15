#!/bin/sh
# A private, signed local registry tests the actual Hex dependency graph without publishing.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
server_pid=
trap '[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true; rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/registry/tarballs" "$work/consumer"
cp "$root/ocex-0.2.0.tar" "$work/registry/tarballs/"
cp "$root/scripts/package-smoke.exs" "$work/consumer/model.exs"
openssl genrsa -out "$work/private.pem" 2048 2>/dev/null
# Build before replacing HEX_HOME, so the installed Hex task remains available.
mix hex.registry build "$work/registry" --name=hexpm --private-key="$work/private.pem"
cat > "$work/serve.exs" <<'ELIXIR'
[root, port_file] = System.argv()
:inets.start()
{:ok, pid} = :inets.start(:httpd, [port: 0, bind_address: {127,0,0,1}, server_name: ~c"archive-test", server_root: String.to_charlist(root), document_root: String.to_charlist(root), modules: [:mod_get, :mod_head]])
port = :httpd.info(pid) |> Keyword.fetch!(:port)
File.write!(port_file, Integer.to_string(port))
Process.sleep(:infinity)
ELIXIR
elixir "$work/serve.exs" "$work/registry" "$work/port" > "$work/http.log" 2>&1 &
server_pid=$!
i=0
while [ ! -f "$work/port" ]; do
  i=$((i+1)); [ "$i" -lt 100 ] || { cat "$work/http.log"; exit 1; }; sleep 0.1
done
export HEX_HOME="$work/hex"
export MIX_INSTALL_DIR="$work/install"
unset OCEX_PATH
mix hex.repo add hexpm "http://127.0.0.1:$(cat "$work/port")" --public-key="$work/registry/public_key"
mix hex.package fetch ocex 0.2.0 --unpack --output "$work/toolkit"
test -f "$work/toolkit/scripts/check-allocator.cpp"
cd "$work/consumer"
elixir model.exs
