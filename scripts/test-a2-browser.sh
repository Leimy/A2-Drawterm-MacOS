#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s DESKTOP_BUILD_DIRECTORY\n' "$0" >&2
    exit 2
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle=$(CDPATH= cd -- "$1" && pwd)
test -x "$bundle/OberonLoader"
test -s "$bundle/DarwinAosDrawtermDesktopAa"
test -s "$bundle/WebBrowser.GofAa"
test -s "$bundle/data/A2BrowserWelcome.html"

work=$(mktemp -d "${TMPDIR:-/tmp}/a2-browser.XXXXXX")
server=
trap 'if [ -n "$server" ]; then kill "$server" 2>/dev/null || :; fi; rm -rf "$work"' EXIT HUP INT TERM

port=$(jot -r 1 40000 60000)
body='<html><head><title>A2 HTTP smoke</title></head><body><h1>Hello over HTTP</h1></body></html>'
bytes=$(printf %s "$body" | wc -c | tr -d ' ')
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$bytes" "$body" > "$work/reply.http"
nc -4 -w 10 -l 127.0.0.1 "$port" < "$work/reply.http" > "$work/request.http" &
server=$!
sleep 0.2

python3 "$repo/scripts/test-a2-desktop-input.py" \
    --loader "$bundle/OberonLoader" \
    --core "$bundle/DarwinAosDrawtermDesktopAa" \
    --cwd "$work" \
    --shell-command "WebBrowser.OpenURL http://127.0.0.1:$port/" \
    --expect-window --expect-log 'ContentLoader: Loading done.' \
    --command-settle 2 --timeout 35
wait "$server" || :
server=
if ! grep -Fq 'GET / HTTP/1.1' "$work/request.http"; then
    printf 'Browser did not request the local HTTP page\n' >&2
    exit 1
fi
printf 'PASS: A2 browser fetched a page from macOS netcat\n'
