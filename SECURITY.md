# Security

iSH+ runs a Linux virtual machine inside an iOS app. Linux inside it is an
ordinary Linux system, with its own users and permissions, but the VM is not
meant as a security boundary between you and the programs you run in it:
they can use the network, your shared folder (Files > iSH+ > Shared) and the
iOS clipboard (`pbcopy`, `pbpaste`).

Things that are security issues for iSH+:

- a way for something outside the VM (a website, another app, another
  device on the network) to run code in it or read its files without you
  starting it;
- iSH+ exposing your pairing file, which lets software use your device's
  developer services.

Please report those privately, with GitHub's
[security advisories](../../security/advisories/new) for this repository,
not in a public issue. Other bugs are welcome as issues.
