VERSION ?= 0.8

GIT_DIRTY := $(shell if git status -s >/dev/null ; then echo dirty ; else echo clean ; fi)
GIT_HASH  := $(shell git rev-parse HEAD)
TOP := $(shell pwd)

all: update-certs

# Remove the temporary files and build stuff
#clean:
#	rm -rf bin $(SUBMODULES) build
#	mkdir $(SUBMODULES)
	#git submodule update --init --recursive --recommend-shallow 

# Regenerate the source file
tar: clean
	tar zcvf ../v-attest_$(VERSION).orig.tar.gz \
		--exclude .git \
		--exclude debian \
		.

# Run shellcheck on the scripts
shellcheck:
	for file in \
		sbin/v-attest* \
		sbin/tpm2-attest \
		sbin/tpm2-send \
		sbin/tpm2-recv \
		sbin/tpm2-policy \
		initramfs/*/* \
		tests/test-enroll.sh \
	; do \
		shellcheck $$file functions.sh ; \
	done

# Fetch several of the TPM certs and make them usable
# by the openssl verify tool.
# CAB file from Microsoft has all the TPM certs in DER
# format.  openssl x509 -inform DER -in file.crt -out file.pem
# https://docs.microsoft.com/en-us/windows-server/security/guarded-fabric-shielded-vm/guarded-fabric-install-trusted-tpm-root-certificates
# However, the STM certs in the cab are corrupted? so fetch them
# separately
update-certs:
	#./refresh-certs
	c_rehash certs

# Fake an overlay mount to replace files in /etc/v-attest with these
fake-mount:
	mount --bind `pwd`/v-attest.conf /etc/v-attest/v-attest.conf
	mount --bind `pwd`/functions.sh /etc/v-attest/functions.sh
	mount --bind `pwd`/sbin/v-attest /sbin/v-attest
	mount --bind `pwd`/sbin/v-attest-tpm-unseal /sbin/v-attest-tpm-unseal
	mount --bind `pwd`/sbin/tpm2-attest /sbin/tpm2-attest
	mount --bind `pwd`/initramfs/scripts/v-attest-bootmode /etc/initramfs-tools/scripts/init-top/v-attest-bootmode
fake-unmount:
	mount | awk '/v-attest/ { print $$3 }' | xargs umount

build/signing.key: | build
	openssl req \
		-new \
		-x509 \
		-newkey "rsa:2048" \
		-nodes \
		-subj "/CN=v-attest.dev/" \
		-outform "PEM" \
		-keyout "$@" \
		-out "$(basename $@).crt" \
		-days "3650" \
		-sha256 \

build/boot/PK.auth: signing.crt
	mkdir -p $(dir $@)
	-./sbin/v-attest uefi-sign-keys
	cp signing.crt PK.auth KEK.auth db.auth "$(dir $@)"

TPMDIR=build/vtpm
TPMSTATE=$(TPMDIR)/tpm2-00.permall
TPMSOCK=$(TPMDIR)/sock
TPM_PID=$(TPMDIR)/swtpm.pid

$(TPM_PID):
	mkdir -p "$(TPMDIR)"
	swtpm socket \
		--tpm2 \
		--flags startup-clear \
		--tpmstate dir="$(TPMDIR)" \
		--pid file="$(TPM_PID).tmp" \
		--server type=tcp,port=9998 \
		--ctrl type=tcp,port=9999 \
		&
	sleep 1
	mv $(TPM_PID).tmp $(TPM_PID)


# Setup a new TPM and
$(TPMDIR)/.created:
	mkdir -p "$(TPMDIR)"
	swtpm_setup \
		--tpm2 \
		--createek \
		--display \
		--tpmstate "$(TPMDIR)" \
		--config /dev/null
	touch $@

# Extract the EK from a tpm state; wish swtpm_setup had a way
# to do this instead of requiring this many hoops
$(TPMDIR)/ek.pub: $(TPMDIR)/.created | build
	$(MAKE) $(TPM_PID)
	TPM2TOOLS_TCTI=swtpm:host=localhost,port=9998 \
	tpm2 \
		createek \
		-c $(TPMDIR)/ek.ctx \
		-u $@

	kill `cat "$(TPM_PID)"`
	@-$(RM) "$(TPM_PID)"

tpm-shell:
	$(MAKE) $(TPM_PID)
	-TPM2TOOLS_TCTI=swtpm:host=localhost,port=9998 \
	PATH=`pwd`/bin:`pwd`/sbin:$(PATH) \
	bash

	-kill `cat "$(TPM_PID)"`
	@-$(RM) "$(TPM_PID)"


# Register the virtual TPM in the attestation server logs with the
# expected value for the kernel that will be booted

$(TPMDIR)/.ekpub.registered: $(TPMDIR)/ek.pub
	./sbin/attest-enroll v-attest-demo < $<
	touch $@

# QEMU tries to boot from the DVD and HD before finally booting from the
# network, so there are attempts to call different boot options and then
# returns from them when they fail.
PCR_CALL_BOOT:=3d6772b4f84ed47595d72a2c4c5ffd15f5bb72c7507fe26f2aaee2c69d5633ba
PCR_SEPARATOR:=df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119
PCR_RETURNING:=7044f06303e54fa96c3fcd1a0f11047c03d209074470b1fd60460c9f007e28a6

$(TPMDIR)/.bootx64.registered: $(BOOTX64) $(TPMDIR)/.ekpub.registered
	./sbin/attest-verify \
		predictpcr \
		$(TPMDIR)/ek.pub \
		4 \
		$(PCR_CALL_BOOT) \
		$(PCR_SEPARATOR) \
		$(PCR_RETURNING) \
		$(PCR_CALL_BOOT) \
		$(PCR_RETURNING) \
		$(PCR_CALL_BOOT) \
		`./bin/sbsign.v-attest --hash-only $(BOOTX64)`
	touch $@

# uefi firmware from https://packages.debian.org/buster-backports/all/ovmf/download
qemu: build/hda.bin $(TPM_PID) $(TPMSTATE)


	#cp /usr/share/OVMF/OVMF_VARS.fd build

	-qemu-system-x86_64 \
		-M q35,accel=kvm \
		-m 4G \
		-drive if=pflash,format=raw,readonly,file=/usr/share/OVMF/OVMF_CODE.fd \
		-drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
		-serial stdio \
		-netdev user,id=eth0 \
		-device e1000,netdev=eth0 \
		-chardev socket,id=chrtpm,path="$(TPMSOCK)" \
		-tpmdev emulator,id=tpm0,chardev=chrtpm \
		-device tpm-tis,tpmdev=tpm0 \
		-drive "file=$<,format=raw" \
		-boot c \

	stty sane
	-kill `cat $(TPM_PID)`
	@-$(RM) "$(TPM_PID)"

server-hda.bin:
	qemu-img create -f qcow2 $@ 4G
build/OVMF_VARS.fd: | build
	cp /usr/share/OVMF/OVMF_VARS.fd $@

UBUNTU_REPO = https://cloud-images.ubuntu.com/focal/current
ROOTFS = focal-server-cloudimg-amd64.img
ROOTFS_TAR = $(basename $(ROOTFS)).tar.gz
$(ROOTFS_TAR):
	wget -O $(ROOTFS_TAR).tmp $(UBUNTU_REPO)/$(ROOTFS_TAR)
	wget -O $(ROOTFS_TAR).sha256 $(UBUNTU_REPO)/SHA256SUMS
	awk '/$(ROOTFS_TAR)/ { print $$1, $$2".tmp" }' < $(ROOTFS_TAR).sha256 \
	| sha256sum -c
	mv $(ROOTFS_TAR).tmp $(ROOTFS_TAR)

$(ROOTFS): $(ROOTFS_TAR)
	tar xvf $(ROOTFS_TAR) $(ROOTFS)
	touch $(ROOTFS) # force timestamp

initramfs/response/img.hash: $(ROOTFS)
	sha256sum - < $< | tee $@

attest-server: $(ROOTFS) register
	# start the attestation server with the paths
	# to find the local copies for the verification tools
	PATH=./bin:./sbin:$(PATH) DIR=. \
	./sbin/attest-server 8080

register: $(TPMDIR)/.ekpub.registered $(TPMDIR)/.bootx64.registered

qemu-server: \
		server-hda.bin \
		build/OVMF_VARS.fd \
		$(BOOTX64) \
		register \
		| $(SWTPM)

	# start the TPM simulator
	-$(RM) "$(TPMSOCK)"
	$(SWTPM) socket \
		--tpm2 \
		--tpmstate dir="$(TPMDIR)" \
		--pid file="$(TPM_PID)" \
		--ctrl type=unixio,path="$(TPMSOCK)" \
		&

	sleep 1

	-qemu-system-x86_64 \
		-M q35,accel=kvm \
		-m 1G \
		-drive if=pflash,format=raw,readonly,file=/usr/share/OVMF/OVMF_CODE.fd \
		-drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
		-serial stdio \
		-netdev user,id=eth0,tftp=.,bootfile=$(BOOTX64) \
		-device e1000,netdev=eth0 \
		-chardev socket,id=chrtpm,path="$(TPMSOCK)" \
		-tpmdev emulator,id=tpm0,chardev=chrtpm \
		-device tpm-tis,tpmdev=tpm0 \
		-drive "file=$<,format=qcow2" \
		-boot n \

	stty sane
	-kill `cat $(TPM_PID)`
	@-$(RM) "$(TPM_PID)" "$(TPMSOCK)"

