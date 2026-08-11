# Changelog

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
