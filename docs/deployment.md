---
title: "Generic procedure to register a computer to attestation server"
summary: >-
  Generic procedure to register a computer to attestation server
---

## Requirements

* A computer running GNU/Linux with `attest-server` installed, used as the attestation server.
* A computer to be attested, equipped with TPM2, running GNU/Linux with `attest-tools` installed.
* A computer running GNU/Linux with `attest-enroll` installed, used to generate enrollment data.

## Enrollment

The public part of the Endorsement Key should be extracted from the TPM2 of the computer to be attested:

```
$ tpm2 createek -G rsa -c ek.ctx -u ek.pub
```

Enrollment data can be generated against this EK on the enrollment computer:

```
$ SIGNING_KEY_PUB=/path/to/sign.pem SIGNING_KEY_PRIV=/path/to/sign-priv.pem \
  attest-enroll -I ek.pub <hostname> 
```

Enrollment data would be generated in `$(pwd)/build/attest`, in which there are some randomly-generated keys
encrypted against the public part of the EK.

After delivering the content of the `build` directory above to the enrollment database of the attestation server
(`$DBDIR`, at `/var/lib/attest-server/` by default), the attestation server can accept trial attestation from the computer
to be attested.

## Trial attestation

During this phase, the computer to be attested could generate quotes and send them to the attestation server,
by executing `tpm2-attest` by its boot system. The server would generate a valid response if only the public
part of the EK could be verified against the signature generated in the enrollment phase, with no concern about
PCRs and event log, since the purpose of this phase is to deliver the encrypted keys to the computer to be
attested, in order for it to make use of the keys to complete its boot procedure. If the boot system is valid,
keys could be decrypted in the TPM2, so the computer to be attested could somehow use these keys. (e.g. to setup
an FDE and use the same key to decrypt it during the next boot)

## Formal attestation

The enrollment database is file based.  The directory structure looks
like:

```
$DBDIR/??/...				# enrollment state for enrolled hosts
$DBDIR/${ekhash:0:2}/${ekhash}/		# <- enrollment state for SHA-256(EKpub)
$DBDIR/${ekhash:0:2}/${ekhash}/		# <- enrollment state for SHA-256(EKpub)
$DBDIR/hostname2ekpub/			# <- index by hostname
$DBDIR/hostname2ekpub/${hostname}	# <- file containing ${hostname}'s SHA-256(EKpub)
$DBDIR/hostname2ekpub/...
```

If `$DBDIR/${ekhash:0:2}/${ekhash}/phase2` exists, the PCR value list obtained from the next attestation would be
recorded at `$DBDIR/${ekhash:0:2}/${ekhash}/pcrs`, and all latter attestations would be compared against the
recorded PCR value list, and failed if unmatched, thus all latter attestations would become formal. A file at
`$DBDIR/tofu_pcrs` in the form of

```
- 0
- 1
- 2
...
```

could be used to list all the index of concerned PCRs.

After the computer to be attested could boot with trial attestation, an empty file could be made at
`$DBDIR/${ekhash:0:2}/${ekhash}/phase2` to make all latter attestations against the enroll EK formal, so only if
all the concerned PCR values keeps the same, the computer to be attested could boot under formal attestation, so
some legal upgrades causing concerned PCR to change will make this computer unable to boot. In this case, the
administrator of the attestation server should be informed to temporarily disable formal attestation for the
corresponding EK by removing `$DBDIR/${ekhash:0:2}/${ekhash}/phase2` and `$DBDIR/${ekhash:0:2}/${ekhash}/pcrs`,
(The old values could be archived) and enable it again after the computer to be attested could boot after the
upgrade.
