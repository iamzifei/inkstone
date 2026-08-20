fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios create_app

```sh
[bundle exec] fastlane ios create_app
```

Create the App Store Connect app record. Interactive: needs a 2FA code.

### ios release

```sh
[bundle exec] fastlane ios release
```

Upload the build, metadata and screenshots, then submit for review.

### ios check

```sh
[bundle exec] fastlane ios check
```

Read-only: does the API key work, and does the app record exist yet?

### ios ship

```sh
[bundle exec] fastlane ios ship
```

First run: create the record, then ship it.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
