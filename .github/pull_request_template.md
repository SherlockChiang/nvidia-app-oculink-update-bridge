## Summary

Describe the user-visible behavior and why the change is needed.

## Validation

- [ ] `dotnet format` passes.
- [ ] Release build passes.
- [ ] `--self-test` passes.
- [ ] Package validation passes when packaging changed.
- [ ] Live NVIDIA integration was run when request rewriting changed.

## Safety

- [ ] The listener remains loopback-only.
- [ ] Upstream hosts and accepted request paths are no broader than necessary.
- [ ] No token, certificate, credential, machine-specific path, or private log is included.
- [ ] The change does not download, redistribute, or modify NVIDIA driver packages.
