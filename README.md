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

The architecture — NAS API for provisioning, host open-iscsi block devices for
data — is the same shape as the official TrueNAS plugin, and deliberately not
the `ZFS over iSCSI` shape: no root SSH into the NAS, containers work, and
multipath is possible.

## What works

| Proxmox VE operation | Implementation |
| --- | --- |
| create / delete a disk | QNAP storage API |
| resize (grow) | `reshaping` API |
| snapshot / delete snapshot | native QNAP snapshots |
| rollback | native, with newer snapshots protected (see below) |
| template + linked clone | **instant clone (ZFS copy-on-write)** |
| branch off any snapshot | **linked clone from a snapshot, without touching it** |
| LXC containers | rootfs on a LUN, formatted ext4 by Proxmox |
| shared storage | several nodes attached to the same target |
| multipath (MPIO) | **experimental** — works by design, verified on one device (see below) |
| iSER (iSCSI over RDMA) | `qnap-transport iser` / `auto` (see below) |

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
| `qnap-fast-clone` | `0` | QNAP fast clone. Nothing in Proxmox triggers it — see below |
| `qnap-sync` | `standard` | ZIL synchronous I/O mode |
| `qnap-threshold` | `80` | thin provisioning warning threshold (%) |
| `qnap-api-port` | `443` | management API port |
| `qnap-verify-tls` | `0` | verify the NAS TLS certificate |
| `qnap-transport` | `tcp` | `tcp`, `iser`, or `auto` (iSER where the node has an RDMA device) — see below |

#### Choose the block size before you create anything

**On RAIDZ the 4k default is very expensive.** With 6-wide RAIDZ2 and
`ashift=12`, a 4k `volblocksize` needs one data sector plus two parity sectors
per block — **three times** the nominal capacity, against the 1.5x RAIDZ2 is
supposed to cost.

**16k gives 4 data + 2 parity = 1.5x**, which is what you want.

**Going above that buys nothing on the same geometry.** A RAIDZ row holds at most
`width - parity` data sectors, and every allocation is rounded up to a multiple
of `parity + 1` sectors. Once a block fills a whole row, the ratio stops
improving:

| `volblocksize` | sectors, 6-wide RAIDZ2, `ashift=12` | cost |
| --- | --- | --- |
| 4k | 1 data + 2 parity | 3.00x |
| 8k | 2 data + 2 parity, padded to 6 | 3.00x |
| **16k** | 4 data + 2 parity | **1.50x** |
| 32k | 2 rows, 8 data + 4 parity | 1.50x |
| 64k | 4 rows, 16 data + 8 parity | 1.50x |

So 16k already reaches the RAIDZ2 minimum here, while a larger value multiplies
read-modify-write: a 4k write from the guest rewrites the entire block, so 64k
costs 16x instead of 4x. Larger values only pay off where 16k does *not* fill a
row — a wider array or RAIDZ3 — or for a workload that is almost entirely
sequential.

**On mirrors there is no padding or parity penalty at all**, so choose by
workload alone: 16k as a default, 8k if the guest mostly does 4k random writes
(databases), at the cost of more metadata and a worse compression ratio.

It **cannot be changed after creation**, so define a second storage if you need a
different value.

#### Fast clone does nothing here

The NAS really does implement offloaded copy: its LUNs advertise Third Party Copy
and a token copy (ODX) between two LUNs works, verified with `ddptctl`.

Nothing in the Proxmox stack ever asks for it. The kernel exposes no copy offload
(`/sys/block/*/queue/copy_max_bytes` does not exist) and neither QEMU nor Proxmox
issues EXTENDED COPY or POPULATE TOKEN, so a disk copy is always read-then-write
over the network.

It costs nothing to leave off, and it would not help anyway: a linked clone moves
no data at all, which beats copying data quickly.

#### Deduplication is rarely worth it

It costs a lot of memory, and if the goal is many copies of the same guest, a
linked clone achieves the same thing far more cheaply.

## iSER (iSCSI over RDMA)

`qnap-transport iser` logs in with iSER (iSCSI Extensions for RDMA, over RoCE)
instead of TCP. `auto` does so on nodes that have an RDMA device
(`/sys/class/infiniband`) and uses TCP on the others, so one storage definition
serves a cluster where only some nodes have RDMA NICs; when the iSER login
fails, `auto` falls back to TCP.

Measured on a QuTS hero TS-873A (ConnectX-4 Lx, 40GbE) from a ConnectX-3 Pro
node, 1 MiB sequential, `fio` direct I/O: write 18.5 vs 13.3 Gbit/s, read
21.2 vs 17.3 Gbit/s for iSER vs TCP, at the same (saturated) NAS CPU. 4k random
I/O is bound by the pool either way.

Requirements:

- iSER enabled on the NAS. QTS / QuTS hero only does this for QNAP-branded cards
  and a short list of others; for a retail Mellanox ConnectX-4 or later card see
  [qnap-iser-enabler](https://github.com/yacchi/qnap-iser-enabler)
- an RDMA-capable NIC on the node (`mlx4_ib` / `mlx5_ib` loaded), and ideally
  flow control (802.3x PAUSE or PFC) on the switch ports, since RoCE handles
  loss poorly

Notes:

- **Do not define a second, built-in `iscsi` storage for the same target.**
  Proxmox's own iSCSI code only recognises `tcp:` sessions: with an iSER session
  it reports that storage as inactive and logs in over TCP as well, so every LUN
  shows up twice. This plugin lists sessions itself for that reason.
- An existing session is kept as it is. To switch a node from TCP to iSER, stop
  the guests on that node that use this storage, then
  `iscsiadm -m node -T <target> -p <portal> -I default --logout`; the next
  `pvestatd` run (within ~10 s) logs in again with the configured transport.
- The plugin uses its own open-iscsi iface, `pve-qnap-iser`, and creates its node
  record directly rather than running a discovery, because a discovery bound to
  one iface rewrites the records of the others. On a node that uses TCP, those
  records are removed before logging in, since Proxmox logs in every record of
  the target.

## Multipath (MPIO) — experimental

Unlike the built-in `ZFS over iSCSI` backend — which hands QEMU an `iscsi://`
URI and therefore bypasses the host's device-mapper layer entirely — this
plugin logs in with the host's open-iscsi stack and gives QEMU a regular block
device. Everything MPIO needs on the initiator side is already in place: PVE
logs into every portal that discovery returns, and the plugin resolves volumes
to `/dev/mapper/3<NAA>` whenever a multipath map exists. Whether MPIO actually
works is decided by the target side, not by the plugin.

**Verified once, on the author's hardware** (TS-873A, single controller,
QuTS hero h5.3.4, target bound to portals on two separate networks):

- `sendtargets` discovery returned both portals and PVE logged into each
- dm-multipath assembled the map on its own; the target advertises ALUA
- `pvesm path` switched from `/dev/disk/by-id/scsi-3<NAA>` to the
  `/dev/mapper` device
- a direct-I/O read survived losing the primary path mid-flight with zero
  errors, continuing on the surviving path

Treat this as one data point, not a support statement. QNAP does not officially
document multipath iSCSI support for QTS or QuTS hero — their MPIO guides only
cover the Windows initiator side — so other models, firmware versions and
dual-controller units may behave differently. Reports welcome either way.

To try it:

1. `apt install multipath-tools` on every node
2. whitelist the LUN WWIDs: `multipath -a 3<naa>` (the NAA is the tail of the
   device that `pvesm path` prints)
3. on the NAS, bind the target to portals on both redundant networks

One QNAP quirk to know about: the portal binding of a target can only be
changed while **no initiator is logged in**, and the NAS needs a few seconds
after the last logout before it accepts the change.

## Templates and clones

**Convert to a template and the whole flow works from the web interface.**

1. create a VM, then *Convert to template*
2. right-click the template, *Clone*, mode **Linked Clone**

That becomes a QNAP instant clone — a ZFS copy-on-write clone, so it is
immediate and takes almost no space.

The web interface only offers *Linked Clone* for templates; that is a Proxmox
restriction, not a limitation of this plugin.

### Branching off a snapshot

Any snapshot of an ordinary guest can be turned into a new guest, from the CLI:

```sh
qm clone 100 200 --snapname before-upgrade --full 0    # VM
pct clone 100 200 --snapname before-upgrade --full 0   # container
```

This is a copy-on-write clone, so it is immediate and costs almost nothing. More
importantly it is **non-destructive**: the source guest keeps running and none of
its snapshots are touched, which is what makes it a safe alternative to rolling
back (see below).

Useful for looking at what a guest contained before an upgrade, recovering one
file, or forking an environment for an experiment.

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
rolling back** (see *Branching off a snapshot* above). The original guest and all
of its snapshots are left untouched:

```sh
qm clone 100 999 --snapname snap1 --full 0
```

## Limitations

- **`raw` only.** There is no qcow2 — these are block devices
- **255 LUNs maximum** (`max_lun_cnt` on the NAS), so 255 VM disks
- **Snapshots cannot be read directly.** Anything that needs to open a snapshot
  as a device will not work; clone it first. In particular `--full 1` together
  with `--snapname` is refused — a full clone copies the source through
  `qemu-img`, which needs that device. Use `--full 0`, which is what you wanted
  from a copy-on-write storage anyway
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
