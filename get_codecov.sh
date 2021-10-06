#!/bin/bash

# Import keys (needs to be run only once):
curl https://keybase.io/codecovsecurity/pgp_keys.asc | gpg --no-default-keyring --keyring trustedkeys.gpg --import

curl -Os https://uploader.codecov.io/latest/macos/codecov
curl -Os https://uploader.codecov.io/latest/macos/codecov.SHA256SUM
curl -Os https://uploader.codecov.io/latest/macos/codecov.SHA256SUM.sig

gpgv codecov.SHA256SUM.sig codecov.SHA256SUM

shasum -a 256 -c codecov.SHA256SUM

chmod +x codecov
# ./codecov -t <token>
