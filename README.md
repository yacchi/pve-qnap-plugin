# pve-qnap-plugin

Use a QNAP NAS (QuTS hero / QTS) as **block storage for Proxmox VE**.

One VM disk maps to one QNAP volume (zvol), exported as one iSCSI LUN.
Snapshots, rollback and clones are performed by the NAS itself, so they do not
depend on qcow2, and linked clones are copy-on-write: instant and nearly free.

> **Status: experimental.** Tested only on the author's hardware
> (TS-873A / QuTS hero h5.3.4 / Proxmox VE 9.2.6). Try it on a disposable VM
> before pointing it at anything you care about.

## Why

With Proxmox, a QNAP is normally used over NFS or SMB. That works, but PVE
snapshots then rely on qcow2 and a clone is a real copy.

QuTS hero runs ZFS, so zvol snapshots and clones are right there. QNAP uses them
in its official Kubernetes CSI driver, but nothing existed for Proxmox.

| NAS | Block storage integration for Proxmox VE |
| --- | --- |
| TrueNAS | official vendor plugin |
| Synology | third-party plugin (btrfs, so no ZFS snapshots) |
| **QNAP** | **nothing** — hence this |

## What works

| Proxmox VE operation | Implementation |
| --- | --- |
| create / delete a disk | QNAP storage API |
| resize (grow) | `reshaping` API |
| snapshot / delete snapshot | native QNAP snapshots |
| rollback | native, with newer snapshots protected (see below) |
| template + linked clone | **instant clone (ZFS copy-on-write)** |
| LXC containers | rootfs on a LUN, formatted ext4 by Proxmox |
| shared storage | several nodes attached to the same target |

## Requirements

- Proxmox VE 8.x or 9.x (pve-storage API 9–15)
- QNAP QuTS hero. QTS has not been tested
- On the NAS, prepared in advance:
  - a **storage pool** — note its id
  - one **iSCSI target** — note its IQN. LUNs are created by the plugin
  - an **account that can use the management API**

## Install

On every node.

### From a release

```sh
apt install ./pve-qnap-plugin_<version>_all.deb
```

### From source

```sh
git clone https://github.com/yacchi/pve-qnap-plugin.git
cd pve-qnap-plugin
make deb
apt install ./pve-qnap-plugin_*_all.deb
```

`make deb` needs nothing but `dpkg-deb` and `make`, so it runs on a PVE node as
is. The package restarts `pvedaemon`, `pveproxy` and `pvestatd` for you, which
is required — Perl modules are loaded when those daemons start.

There is also `make install` for a plain file copy, in which case run
`make reload` afterwards.

## Configure

```sh
pvesm add qnap qnap-iscsi \
    --server 10.0.0.10 \
    --portal 10.0.1.10 \
    --target iqn.2004-04.com.qnap:ts-873a:iscsi.example.0123456 \
    --qnap-pool-id 2 \
    --username proxmox \
    --content images,rootdir \
    --shared 1 \
    --password
```

`server` is the **management API** host and `portal` is the **iSCSI data path**
host. They are separate because management and storage are often on different
networks.

The password is stored in `/etc/pve/priv/storage/<storeid>.pw`, which is
synchronised across the cluster and readable by root only.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `qnap-pool-id` | (required) | storage pool id on the NAS |
| `qnap-blocksize` | `16k` | zvol block size. **Cannot be changed later** |
| `qnap-compression` | `1` | LZ4 compression |
| `qnap-dedup` | `0` | deduplication |
| `qnap-ssd-cache` | `1` | SSD read cache |
| `qnap-fast-clone` | `0` | QNAP fast clone (unusable from Proxmox) |
| `qnap-sync` | `standard` | ZIL synchronous I/O mode |
| `qnap-threshold` | `80` | thin provisioning warning threshold (%) |
| `qnap-api-port` | `443` | management API port |
| `qnap-verify-tls` | `0` | verify the NAS TLS certificate |

#### Choose the block size before you create anything

**On RAIDZ the 4k default is very expensive.** With 6-wide RAIDZ2 and
`ashift=12`, a 4k `volblocksize` needs one data sector plus two parity sectors
per block — **three times** the nominal capacity, against the 1.5x RAIDZ2 is
supposed to cost.

**16k gives 4 data + 2 parity = 1.5x**, which is what you want. Use 64k if the
workload is mostly sequential. It **cannot be changed after creation**, so define
a second storage if you need a different value.

#### Deduplication is rarely worth it

It costs a lot of memory, and if the goal is many copies of the same guest, a
linked clone achieves the same thing far more cheaply.

## Templates and clones

**Convert to a template and the whole flow works from the web interface.**

1. create a VM, then *Convert to template*
2. right-click the template, *Clone*, mode **Linked Clone**

That becomes a QNAP instant clone — a ZFS copy-on-write clone, so it is
immediate and takes almost no space.

The web interface only offers *Linked Clone* for templates; that is a Proxmox
restriction, not a limitation of this plugin. To branch off an arbitrary
snapshot of a normal VM, use the CLI:

```sh
qm clone 100 200 --snapname before-upgrade --full 0
```

## About rollback

**Rolling back to a snapshot destroys every snapshot taken after it.** That is
how ZFS works, and the QNAP API does it without warning.

So this plugin implements the standard `volume_rollback_is_possible` hook and
lets Proxmox refuse anything but the most recent snapshot — the same behaviour
as the built-in ZFS storage:

```
can't rollback, 'snap1' is not most recent snapshot on 'qnap-iscsi:vm-100-disk-0'
```

**To reach an older state while keeping the snapshots after it, clone instead of
rolling back.** The original disk is left untouched:

```sh
qm clone 100 999 --snapname snap1 --full 0
```

## Limitations

- **`raw` only.** There is no qcow2 — these are block devices
- **255 LUNs maximum** (`max_lun_cnt` on the NAS), so 255 VM disks
- **Snapshots cannot be read directly.** Anything that needs to open a snapshot
  as a device will not work; clone it first
- QTS (non-ZFS models) is untested

## How it works

QNAP exposes several APIs and the right one differs per operation.

| Operation | Endpoint |
| --- | --- |
| create / delete / resize a LUN | `/api/storage/v1/volumes` |
| list LUNs, map to a target | `/api/iscsi/v1/...` |
| snapshots and rollback | `/api/snapmgr/v1/...` |
| instant clone | `/cgi-bin/disk/snapshot.cgi?func=instant_clone_qsnapshot` |

The traps worth knowing:

- `POST /api/iscsi/v1/luns` **registers an existing block device**; it does not
  create one. Given a device that does not exist it reports success and does
  nothing
- `PUT /api/iscsi/v1/luns/:i` with `lun_capacity` changes only what the API
  reports. Resize through `/api/storage/v1/volumes/:i/reshaping`
- `clone_qsnapshot` is a full copy. The copy-on-write clone is
  `instant_clone_qsnapshot`
- Delete in the order unmap → snapshots → volume. A mapped LUN fails with
  `-14 Failed to unmount volume`, a message unrelated to the actual cause

The full reference is in [`docs/qnap-api.md`](docs/qnap-api.md).

## License

GPL-3.0. See [LICENSE](LICENSE).

This plugin subclasses `PVE::Storage::Plugin` from `libpve-storage-perl`, which
is AGPL-3.0-or-later. AGPLv3 §13 explicitly permits combining it with GPLv3 code;
the resulting combination carries the AGPL obligations for the Proxmox parts.

## Notices

Not affiliated with, endorsed by, or supported by QNAP Systems, Inc. or
Proxmox Server Solutions GmbH. QNAP, QuTS hero, QTS and Proxmox are trademarks of
their respective owners and are used here only to say what this software talks to.

The management API used here is not publicly documented by QNAP. The behaviour
this plugin relies on was determined for interoperability, from the author's own
hardware and from QNAP's CSI driver, which QNAP publishes under Apache-2.0. No
QNAP code is included or redistributed. See [`docs/qnap-api.md`](docs/qnap-api.md)
for details. QNAP may change any of it without notice.
