# What a build needs from Homebrew. The libraries the app bundles (OpenSSL,
# libxcrypt, OpenLDAP, libssh2) are built from source by core/deps/build.sh
# instead: Homebrew's only run on the macOS they were built on, and there
# are none for Intel.
brew "ca-certificates" # the CA bundle the app ships for its OpenSSL
brew "bear"            # make -C core compdb (editor support)
