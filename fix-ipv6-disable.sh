
#!/bin/bash

GRUB_FILE="/etc/default/grub"

if [[ $EUID -ne 0 ]]; then
    echo "Script harus dijalankan sebagai root!"
    exit 1
fi

if [[ ! -f "$GRUB_FILE" ]]; then
    echo "File GRUB tidak ditemukan!"
    exit 1
fi

if ! grep -q 'ipv6.disable=1' "$GRUB_FILE"; then
    echo "IPv6 tidak dinonaktifkan melalui konfigurasi GRUB."
    exit 0
fi

sed -i 's/\(^\| \)ipv6\.disable=1\($\| \)/ /g' "$GRUB_FILE"

if update-grub; then
    echo "IPv6 berhasil diperbaiki pada konfigurasi GRUB."
    echo "Silakan reboot VPS untuk menerapkan perubahan."
else
    echo "Gagal memperbarui GRUB!"
    exit 1
fi
