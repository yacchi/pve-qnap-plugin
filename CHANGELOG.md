# Changelog

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
