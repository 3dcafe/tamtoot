# Ask the desktop agent to write and run tests

In the Agent panel, expand **Agent options** and enable **Write and run tests**.
The checkbox is off by default and saved as a device preference. It is shown on
Windows, macOS and Linux. Execution requires a local project folder; mobile,
web and enhanced privacy mode do not expose the test action.

The option adds instructions to create meaningful tests, choose the project's
existing test framework, run focused checks, fix failures and report actual
results. It also enables the `run_tests` JSON action. It does not install SDKs or
automatically generate a test suite independently of the model.

Every command shows a confirmation containing its executable and argument list,
even in YOLO mode. Approving a test command executes project code. Tamtoot starts
the process in the primary project folder and supplies arguments directly,
without a shell command string. Arguments cannot explicitly name absolute or
parent-directory paths. This is not an operating-system sandbox for test code.

Supported entry points:

- `flutter test`, `flutter analyze`, `dart test`, `dart analyze`;
- `dotnet test`, `dotnet build`;
- `python -m pytest`, `python3 -m unittest`, `pytest`;
- `npm test`, `pnpm test`, `yarn test` (and `run test`);
- `cargo test`, `go test`, `mvn test`, `ctest`.

Shells, arbitrary executables and installation commands are not exposed through
this action. `run_command` remains unavailable.

Flutter and Dart use the configured Flutter SDK when supplied. On Windows the
configured Flutter SDK is launched through its cached Dart executable and Flutter
tools snapshot, avoiding a batch-file shell. .NET uses the configured SDK path
or normal SDK discovery. Other native runners use PATH. On Windows, batch-only
`npm` / `pnpm` / `yarn` / `mvn` launchers are reported unavailable; they are not
passed through cmd.exe. Flutter on Windows needs its SDK path configured. If the SDK cannot be started,
the host reports that no verification ran; installing/configuring it remains a
user task. Desktop store sandbox restrictions can also prevent process launch.

A command has a two-minute timeout and a one-MiB output capture limit. Stopping
the agent terminates the runner and its descendants using the existing desktop
process-tree helper. Output and the exit code are returned to the model. After
another edit the agent must attempt verification again before finishing.

The final message includes the host's command result, or an explicit denial /
unavailable-runner note. A failed command produces an unsuccessful agent result;
a missing environment is reported as an unverified result rather than a test pass.
A zero exit code establishes only what that command actually checked: a build
command is not proof that tests ran or that the tests cover all behavior.
