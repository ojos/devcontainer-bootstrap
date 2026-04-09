# Release Account Guide

This repository is intended for release operations of devcontainer-bootstrap.

## Tag release

1. Push commit to default branch.
2. Create and push tag (`vX.Y.Z`).
3. GitHub Actions workflow `Release` publishes artifacts.

## Artifacts

- bootstrap.sh
- doctor.sh
- SHA256SUMS
