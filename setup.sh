#!/bin/zsh
# One-time setup: installs what the app needs and builds Pendant.app.
# Safe to run again; it skips what is already done.
set -e
cd "$(dirname "$0")"

# The version of pendant-cli this app was tested with.
PENDANT_CLI_REPO="https://github.com/MAkcanca/pendant-cli.git"
PENDANT_CLI_COMMIT="5e0eace94042096a74944861cc4d60060cd3aa8f"

stop() { echo; echo "Setup stopped: $1"; exit 1; }

echo "== Checking this Mac"
[[ "$(uname -m)" == "arm64" ]] || stop "This app needs a Mac with Apple silicon (M1 or newer)."
xcode-select -p >/dev/null 2>&1 || stop "Apple's Command Line Tools are missing. Run:  xcode-select --install   then run this script again."
command -v brew >/dev/null 2>&1 || stop "Homebrew is missing. Install it from https://brew.sh then run this script again."

echo "== Installing Python 3.12 and Opus with Homebrew"
brew install python@3.12 opus
PYTHON="$(brew --prefix python@3.12)/bin/python3.12"

echo "== Fetching pendant-cli (the Bluetooth client, by Mustafa Akcanca)"
mkdir -p vendor
if [[ ! -d vendor/pendant-cli ]]; then
    git clone "$PENDANT_CLI_REPO" vendor/pendant-cli
fi
git -C vendor/pendant-cli fetch -q origin
git -C vendor/pendant-cli checkout -q "$PENDANT_CLI_COMMIT"

echo "== Creating the Python environment"
[[ -x runtime/venv/bin/python ]] || "$PYTHON" -m venv runtime/venv
runtime/venv/bin/pip install -q -e "vendor/pendant-cli[dev,opus]"
(cd vendor/pendant-cli && ../../runtime/venv/bin/python scripts/gen_proto.py >/dev/null)

echo "== Building the app (the first build takes several minutes)"
PendantApp/build.sh

echo
echo "Done. The app is at:  PendantApp/build/Pendant.app"
echo "Open it with:         open PendantApp/build/Pendant.app"
echo "Keep this folder where it is: the app uses the Python environment inside it."
