# Boot hook, sourced in background by /etc/init.d/S98_lunch_init on every boot.
# The file name is fixed by the vendor script. It only starts our helpers and never reboots.
if [ -f /userdata/e1sync/e1sync.sh ]; then
  /bin/sh /userdata/e1sync/e1sync.sh </dev/null >/dev/null 2>&1 &
fi
# WiFi uploader (installed from the Mac app; delete /userdata/e1wifi to remove)
if [ -x /userdata/e1wifi/e1wifi ]; then
  /userdata/e1wifi/e1wifi </dev/null >/dev/null 2>&1 &
fi
