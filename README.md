
# V-Attest: A remote attestation toolset

V-Attest has the following goals to tailor the tools originally
provided by Safeboot:

* Decompose Safeboot into several mutually dependent packages which are
  dedicated to their own usage.

* Lower their privilege requirement to fit the principle of least
  privilege (e.g. remove the requirement for mounting file system when
  dealing with temporary directories).

* Make it possible to integrate these tools to much wide-ranging scenarios
  other than the one of Safeboot.

-----

## Building debian package

```
# apt install debhelper-compat tpm2-tools, swtpm
$ git clone <public repository>
$ cd v-attest/debian
$ dpkg-buildpackage -b --no-sign
```

Note the resulted `attest-server` package depends at runtime on `swtpm2-daemon`
from the repository with the same name.

## Contributing to `V-Attest`

Please create [issues on github](/issues)
if you run into problems and pull requests to solve problems or add
features are welcome!
