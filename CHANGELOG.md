# Changelog

## 0.2.0

- Support LXC containers. Proxmox creates a raw volume and formats it, which is
  what this plugin already produced, so declaring `rootdir` was all that was
  needed. Add it to `--content` to use it.

## 0.1.0

- First release. Disk create/delete/resize, snapshots, rollback with newer
  snapshots protected, templates and copy-on-write linked clones.
