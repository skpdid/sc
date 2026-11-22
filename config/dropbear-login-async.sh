#!/bin/bash
#
# dropbear-login-sync — tambahkan baris login Dropbear yang BARU ke
# /etc/dropbear-login.log, tanpa duplikat dan tanpa mengosongkan auth.log.
#
# Kenapa bukan "grep ... >> file":
#   grep membaca ulang seluruh auth.log tiap menit, jadi baris yang sama
#   ditambahkan berulang kali (100 baris cocok = 144.000 duplikat/hari).
#
# Cara kerja:
#   1. simpan inode, offset byte, dan hash 512 byte tepat sebelum offset
#   2. baca hanya byte setelah offset (tail -c +N) -> nol duplikat
#   3. inode berubah (logrotate) / file mengecil / isi sebelum offset berubah
#      (truncate lalu ditulis ulang) -> baca ulang dari awal, lalu buang
#      baris yang sudah ada di snapshot
#   4. snapshot dipangkas ke N baris terakhir supaya tidak tumbuh selamanya
#
# Pasang di cron tiap menit:
#   * * * * * /usr/local/bin/dropbear-login-sync

set -uo pipefail

LOG="${DB_LOG:-/var/log/auth.log}"
SNAP="${DB_SNAP:-/etc/dropbear-login.log}"
STATE="${DB_STATE:-/etc/dropbear-login.state}"
KEEP="${DB_KEEP:-20000}"

[ -r "$LOG" ] || exit 0

# winhash <offset> — md5 dari maksimal 512 byte tepat sebelum offset.
# Dipakai untuk mendeteksi file yang dipotong lalu ditulis ulang: kalau isi
# sebelum offset berubah, offset lama tidak lagi menunjuk ke tempat yang sama.
winhash() {
	local off="$1" start
	[ "${off:-0}" -le 0 ] && return
	if [ "$off" -gt 512 ]; then start=$((off - 511)); else start=1; fi
	tail -c +"$start" "$LOG" 2>/dev/null | head -c 512 | md5sum | cut -d' ' -f1
}

cur_ino=$(stat -c %i "$LOG" 2>/dev/null || echo 0)
cur_size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)

last_ino=0
last_off=0
last_win=""
if [ -s "$STATE" ]; then
	read -r last_ino last_off last_win <"$STATE" || true
fi
[ -n "${last_ino:-}" ] || last_ino=0
[ -n "${last_off:-}" ] || last_off=0
[ -n "${last_win:-}" ] || last_win=""

reset=0
if [ "$cur_ino" != "$last_ino" ]; then
	reset=1                                        # logrotate: file baru
elif [ "$cur_size" -lt "$last_off" ]; then
	reset=1                                        # file dipotong
elif [ "$last_off" -gt 0 ] && [ "$(winhash "$last_off")" != "$last_win" ]; then
	reset=1                                        # isi sebelum offset berubah
fi

[ "$reset" -eq 0 ] && [ "$cur_size" -eq "$last_off" ] && exit 0

tmp="$(mktemp "${SNAP}.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT

[ -s "$SNAP" ] && cat "$SNAP" >"$tmp"

if [ "$reset" -eq 1 ]; then
	# baca seluruh file, lalu buang baris yang sudah ada di snapshot
	tail -c +1 "$LOG" 2>/dev/null | grep -w "auth succeeded" >>"$tmp" 2>/dev/null
	awk '!seen[$0]++' "$tmp" >"${tmp}.dedup" && mv "${tmp}.dedup" "$tmp"
else
	tail -c +$((last_off + 1)) "$LOG" 2>/dev/null |
		grep -w "auth succeeded" >>"$tmp" 2>/dev/null
fi

if [ "$(wc -l <"$tmp")" -gt "$KEEP" ]; then
	tail -n "$KEEP" "$tmp" >"${tmp}.trim" && mv "${tmp}.trim" "$tmp"
fi

mv "$tmp" "$SNAP"
chmod 600 "$SNAP" 2>/dev/null
printf '%s %s %s\n' "$cur_ino" "$cur_size" "$(winhash "$cur_size")" >"$STATE"
