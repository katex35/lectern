# Contributing

Thank you for helping. A few things keep Lectern easy to work on:

- `swift build` and `swift test` pass before a pull request. The tests need no account and no microphone.
- New behavior in `LecternCore` comes with a test. Network calls are tested against `MockHTTP`, never a real service.
- User-facing text goes into both `Sources/Lectern/Resources/en.lproj` and `tr.lproj`.
- Keys stay in the Keychain and in request headers, never in URLs, logs or files.
- Lectern sends recordings and notes only to the services the user connected. Please keep it that way.

To see your change on screen without an account:

```sh
LECTERN_FAKE_AI=1 LECTERN_SIMULATE=60 LECTERN_LIBRARY=/tmp/lectern-test swift run Lectern
```
