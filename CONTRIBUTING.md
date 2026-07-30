# Contributing

Issues and pull requests are welcome. Keep changes narrowly scoped and explain
which NVIDIA App and Windows 11 versions were tested.

## Development

Requirements:

- Windows 11 x64
- .NET SDK 10.0.302 (pinned by `global.json`)
- PowerShell 7 for development (installers remain Windows PowerShell 5.1
  compatible)

```powershell
dotnet restore .\NvidiaAppOculinkShim.slnx
dotnet build .\NvidiaAppOculinkShim.slnx --configuration Release --no-restore
dotnet run --project .\src\NvidiaAppOculinkShim --configuration Release --no-build -- --self-test
.\tests\Invoke-IntegrationTest.ps1 -Configuration Release
dotnet format .\NvidiaAppOculinkShim.slnx --verify-no-changes --no-restore
.\build\Publish-Package.ps1
```

The live integration test contacts NVIDIA's official metadata service. CI runs
it on the weekly schedule and when manually dispatched, rather than making a
third-party service a hard dependency of every pull request.

The isolated SCM lifecycle/recovery test intentionally requires elevation. It
uses the dedicated `NvidiaAppOculinkShimV4Test` service name and a dynamic port;
it refuses to remove a same-named service with a different executable path.

```powershell
.\tests\Invoke-ServiceLifecycleTest.Elevated.ps1
```

The test removes its temporary service and ProgramData directory in `finally`.
It never stops or deletes the installed `NvidiaAppOculinkShim` service.

## Pull requests

- Do not weaken loopback binding, exact browser-Origin checks, path allowlists,
  TLS validation, payload limits, ACL checks, or rollback behavior.
- Do not add driver download or installation behavior.
- Keep NVIDIA device IDs and driver versions dynamic; fixture IDs may appear
  only in isolated tests.
- Add or update tests for request rewriting and installer state transitions.
- Never commit runtime logs, PID files, installed configuration, URL tokens,
  signing certificates, signing passwords, or machine-specific paths.
- Preserve unrelated NVIDIA configuration during repair and selective
  uninstall.

By contributing, you agree that your contribution is licensed under the MIT
License.
