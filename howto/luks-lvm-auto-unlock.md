# LUKS2 + LVM Auto-Unlock with Keyport

This HOWTO creates a new LUKS2-encrypted device, puts LVM inside it, and unlocks it at boot with a Keyport-managed key. An independent offline recovery passphrase is retained.

> **Warning:** `cryptsetup luksFormat` destroys existing data. Verify the target device first.

## Architecture

```text
/dev/sdb1 -> LUKS2 -> /dev/mapper/secure -> LVM PV -> VG secure
          -> LV data -> ext4 -> /mnt/data
```

Examples:

```text
Device:        /dev/sdb1
LUKS mapper:   secure
VG:            secure
LV:            data
Mount point:   /mnt/data
Keyport scope: server01
Keyport key:   luks-secure
```

## 1. Verify the target

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,UUID,MOUNTPOINTS
findmnt /dev/sdb1
pvs
```

The target must be the intended empty device and must not be mounted or in use by LVM.

## 2. Install and configure Keyport

```bash
curl -fsSL https://raw.githubusercontent.com/aspanta/keyport/main/clients/debian/keyport-client-install | bash
keyport-client -v
```

Create a dedicated scope and credential for the host and restrict the scope to the host's source address/network.

Generate a KEK:

```bash
keyport-client kek generate
```

Configure `/opt/keyport-client/keyport-client.conf`:

```ini
KEYPORT_URL=https://keyport.example.com
KEYPORT_SCOPE=server01
KEYPORT_API_KEY=<API-key>
KEYPORT_KEK_BASE64=<generated-KEK>
```

Protect and test it:

```bash
chown root:root /opt/keyport-client/keyport-client.conf
chmod 600 /opt/keyport-client/keyport-client.conf
keyport-client list
echo $?
```

Expected exit status: `0`.

## 3. Generate the LUKS automation key

```bash
umask 077
printf '%s' "$(keyport-client create luks-secure --push)" > /root/luks-secure.key
wc -c /root/luks-secure.key
```

Expected size: 64 bytes. Verify the Keyport round trip:

```bash
keyport-client get luks-secure > /root/luks-secure.test
cmp /root/luks-secure.key /root/luks-secure.test
echo $?
rm -f /root/luks-secure.test
```

Expected comparison result: `0`.

## 4. Create LUKS2

**This destroys existing contents of the target device.**

```bash
cryptsetup luksFormat --type luks2 /dev/sdb1 /root/luks-secure.key
cryptsetup luksDump /dev/sdb1
LUKS_UUID="$(cryptsetup luksUUID /dev/sdb1)"
echo "$LUKS_UUID"
ls -l "/dev/disk/by-uuid/$LUKS_UUID"
```

Use `/dev/disk/by-uuid/<LUKS-UUID>` from this point onward.

## 5. Add offline recovery

```bash
cryptsetup luksAddKey "/dev/disk/by-uuid/$LUKS_UUID" --key-file /root/luks-secure.key
```

Enter a strong new recovery passphrase and store it independently from this host and Keyport.

Verify:

```bash
cryptsetup luksDump "/dev/disk/by-uuid/$LUKS_UUID"
```

There should be separate active keyslots for the Keyport key and offline recovery passphrase.

## 6. Test both unlock paths

Keyport:

```bash
keyport-client get luks-secure |
  cryptsetup open --key-file=- "/dev/disk/by-uuid/$LUKS_UUID" secure
cryptsetup status secure
cryptsetup close secure
```

Offline recovery:

```bash
cryptsetup open "/dev/disk/by-uuid/$LUKS_UUID" secure
cryptsetup status secure
cryptsetup close secure
```

Reopen through Keyport:

```bash
keyport-client get luks-secure |
  cryptsetup open --key-file=- "/dev/disk/by-uuid/$LUKS_UUID" secure
```

After both paths work:

```bash
rm -f /root/luks-secure.key
```

`rm` is not a guarantee of physical secure erasure on SSD, thin-provisioned, or copy-on-write storage.

## 7. Create LVM and ext4

```bash
pvcreate /dev/mapper/secure
vgcreate secure /dev/mapper/secure
lvcreate -l 100%FREE -n data secure
pvs
vgs
lvs

mkfs.ext4 -L data /dev/secure/data
blkid /dev/secure/data

mkdir -p /mnt/data
mount /dev/secure/data /mnt/data
findmnt /mnt/data
umount /mnt/data
```

## 8. Create the unlock helper

Create `/usr/local/sbin/keyport-luks-unlock`:

```bash
#!/bin/bash
set -u

DEVICE="/dev/disk/by-uuid/<LUKS-UUID>"
MAPPER="secure"
KEY_NAME="luks-secure"
KEYPORT="/usr/local/sbin/keyport-client"
MAX_ATTEMPTS=12
RETRY_DELAY=5

if cryptsetup status "$MAPPER" >/dev/null 2>&1; then
    exit 0
fi

for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    echo "keyport-luks-unlock: attempt ${attempt}/${MAX_ATTEMPTS}"

    if "$KEYPORT" get "$KEY_NAME" |
       cryptsetup open --key-file=- "$DEVICE" "$MAPPER"; then
        if cryptsetup status "$MAPPER" >/dev/null 2>&1; then
            echo "keyport-luks-unlock: ${MAPPER} unlocked"
            exit 0
        fi
    fi

    [ "$attempt" -lt "$MAX_ATTEMPTS" ] && sleep "$RETRY_DELAY"
done

echo "keyport-luks-unlock: failed to unlock ${MAPPER}" >&2
exit 1
```

Replace `<LUKS-UUID>`, then:

```bash
chown root:root /usr/local/sbin/keyport-luks-unlock
chmod 700 /usr/local/sbin/keyport-luks-unlock
bash -n /usr/local/sbin/keyport-luks-unlock
```

The plaintext key is streamed directly from Keyport to `cryptsetup`; no plaintext key file is created during boot.

## 9. Create the systemd service

Create `/etc/systemd/system/keyport-luks-unlock.service`:

```ini
[Unit]
Description=Unlock LUKS volume using Keyport
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/keyport-luks-unlock
RemainAfterExit=yes
```

Reload systemd:

```bash
systemctl daemon-reload
```

The service is not a generic prerequisite of `local-fs.target`. The dependent filesystem explicitly requires it.

## 10. Configure /etc/fstab

Get the filesystem UUID:

```bash
blkid -s UUID -o value /dev/secure/data
```

Add:

```fstab
UUID=<FS-UUID> /mnt/data ext4 defaults,x-systemd.requires=keyport-luks-unlock.service,x-systemd.after=keyport-luks-unlock.service 0 2
```

These options instruct the systemd fstab generator to add requirement and ordering dependencies when the corresponding mount unit is generated. The generated mount-unit configuration has **not** been refreshed yet.

## 11. Reload systemd after editing fstab

```bash
systemctl daemon-reload
findmnt --verify
systemd-escape --path --suffix=mount /mnt/data
```

Expected unit name: `mnt-data.mount`.

Now inspect the generated unit:

```bash
systemctl cat mnt-data.mount
systemctl show mnt-data.mount -p Requires -p After --no-pager
```

`keyport-luks-unlock.service` should now appear in the generated requirement and ordering information.

## 12. Test the dependency chain

```bash
umount /mnt/data 2>/dev/null || true
vgchange -an secure
cryptsetup close secure
systemctl stop keyport-luks-unlock.service

systemctl start mnt-data.mount
```

Expected chain:

```text
mnt-data.mount -> keyport-luks-unlock.service -> Keyport
               -> cryptsetup open -> /dev/mapper/secure
               -> LVM activation -> /dev/secure/data -> /mnt/data
```

Verify:

```bash
cryptsetup status secure
pvs
vgs
lvs
findmnt /mnt/data
df -h /mnt/data
systemctl status keyport-luks-unlock.service mnt-data.mount --no-pager
```

LVM normally activates the LV after the decrypted PV appears. If the target distribution does not do this automatically, configure its normal LVM activation mechanism before relying on boot mounting.

## 13. Test idempotency and reboot

```bash
/usr/local/sbin/keyport-luks-unlock
echo $?
```

Expected exit status: `0`.

Reboot:

```bash
reboot
```

After boot:

```bash
cryptsetup status secure
pvs
vgs
lvs
findmnt /mnt/data
df -h /mnt/data
systemctl status keyport-luks-unlock.service mnt-data.mount --no-pager
test ! -e /root/luks-secure.key && echo "No local plaintext key"
```

## 14. Test offline recovery

When safe:

```bash
umount /mnt/data
vgchange -an secure
cryptsetup close secure

cryptsetup open "/dev/disk/by-uuid/<LUKS-UUID>" secure
vgchange -ay secure
mount /mnt/data
findmnt /mnt/data
```

Enter the offline recovery passphrase when prompted.

## 15. Test fail-closed behavior

Temporarily make the Keyport scope or credential unavailable and reboot.

Expected:

```text
Linux boots
 -> Keyport retrieval fails
 -> LUKS remains locked
 -> VG secure is unavailable
 -> /mnt/data is not mounted
```

Verify:

```bash
cryptsetup status secure
vgs
findmnt /mnt/data
systemctl status keyport-luks-unlock.service mnt-data.mount --no-pager
journalctl -u keyport-luks-unlock.service -b --no-pager
```

The system must not fall back to a persistent local plaintext automation key.

Restore Keyport access. A failed oneshot service may remain failed, so reset it before retrying:

```bash
systemctl reset-failed keyport-luks-unlock.service mnt-data.mount
systemctl start mnt-data.mount

cryptsetup status secure
vgs
findmnt /mnt/data
```

## Security model

Two independent LUKS unlock paths remain:

```text
                    LUKS2
                      |
          +-----------+-----------+
          |                       |
          v                       v
 Keyport automation        Offline recovery
      keyslot                  keyslot
          |                       |
          v                       v
 encrypted value          recovery passphrase
 in Keyport
          |
          v
 client-side KEK
```

For unattended boot, Keyport returns the encrypted value, the client decrypts it locally with its KEK, and the plaintext key is streamed directly to `cryptsetup`.

The Keyport server does not store the plaintext LUKS key, and the host does not retain a persistent plaintext copy of the automation key.
