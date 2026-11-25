# Changelog

## 0.4.2

- Activate the storage under a per-node lock. At boot pvestatd and pve-guests
  activated it at the same time; both found no session, and the one that lost
  the race failed its iSER login and fell back to TCP, leaving an iSER and a TCP
  session to the same target (every LUN visible twice).

## 0.4.1

- Widen the QNAP editor in the web UI (800px, 120px labels); at the default
  600px the hints were cut off and longer labels wrapped.

## 0.4.0

- Add a QNAP editor to the Proxmox VE web UI, so the storage can be added and
  edited there (iSER options included) instead of only with `pvesm`. The web
  UI has no hook for custom storage types, so the editor is appended to
  `pvemanagerlib.js` and a dpkg trigger re-adds it after each pve-manager
  update. Reload the page bypassing the cache after installing.

## 0.3.1

- Log in to the QNAP API again when it answers `811 The session is not found.`
  The NAS answers this way, instead of with `-22`, after it has rebooted, so
  the storage stayed offline in `pvestatd` until the daemons were restarted.

## 0.3.0

- Add `qnap-transport` (`tcp`, `iser`) for iSER (iSCSI over RDMA), and
  `qnap-iser-nodes` to choose the nodes that use it (all when unset); the other
  nodes use TCP. A selected node without an RDMA device, or whose iSER login
  fails, also uses TCP. The default stays `tcp`.
- List iSCSI sessions in the plugin instead of through
  `PVE::Storage::ISCSIPlugin`, which only recognises `tcp:` sessions and would
  mark the storage inactive (and log in over TCP on top) with iSER.

## 0.2.4

- Stop listing every volume for operations that only need an id. Snapshots,
  rollback, `create_base` and `clone_image` now resolve the name through the
  pool-scoped listing (~0.25s) instead of the full one (~7.6s).
- Resolve the LUN for `path` by name instead of going through the volume to
  find its index. Proxmox calls `path` for every operation that touches a
  disk, so this was the most expensive call in the plugin: 7.9s to 0.3s.

`free_image`, `volume_size_info` and `volume_resize` still use the full
listing, because the pool-scoped one carries no size, no `mapping_name` and
no `provision_type`.

## 0.2.3

- List volumes once per `pvesm list` instead of twice. Proxmox calls
  `list_images` once per content type, and this storage declares both
  `images` and `rootdir`, so listing cost twice what it needed to. The cache
  lives only for the duration of one `list_volumes` call, so nothing else
  sees a stale view of the NAS.

## 0.2.2

- Fix disk creation failing with "'storage-<id>'-locked command timed out",
  which made any OVMF VM impossible to create. The NAS does not create a LUN
  for a zvol below 1 GiB — it reports success and creates the volume, but no
  LUN follows — so small requests are now rounded up with a warning. PVE
  allocates 1 MiB for `efidisk0` and 4 MiB for `tpmstate0` by itself.
- Wait for a new volume by polling the iSCSI LUN listing instead of the
  volume listing: 0.25s per poll against 7.6s. The wait is also against a
  deadline now, so its timeout means seconds rather than minutes.
- List volumes once per allocation instead of twice.
- Keep the API path normalisation in one place, so error messages no longer
  read "/apistorage/v1/volumes".

## 0.2.1

- Fix linked clones from a snapshot. Proxmox activates the source snapshot
  first, and the plugin refused that, so `qm clone --snapname ... --full 0`
  failed outright.
- Refuse to delete a snapshot a linked clone was made from, naming the clone.
  The NAS answers "Success" while deleting nothing in that case, which left
  Proxmox and the NAS quietly disagreeing about what exists.
- Recover a volume left without a LUN. A delete interrupted partway leaves one
  behind, and the NAS then refuses to delete it at all.

## 0.2.0

- Support LXC containers. Proxmox creates a raw volume and formats it, which is
  what this plugin already produced, so declaring `rootdir` was all that was
  needed. Add it to `--content` to use it.

## 0.1.0

- First release. Disk create/delete/resize, snapshots, rollback with newer
  snapshots protected, templates and copy-on-write linked clones.
