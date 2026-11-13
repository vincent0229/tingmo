#!/bin/sh
# e1sync — runs on the Sogou E1 pen (Buildroot / busybox ash).
# Module 1: keep the clock correct.
#   - after boot, if the hardware clock was reset (battery fully drained), fall back to the
#     last known good time and mark the clock as "estimated"
#   - whenever WiFi is up and the clock has not been synced recently, run ntpd once,
#     then write the result back to the hardware clock (hwclock -w)
#   - log every clock step per boot so recordings made before a sync can be corrected later
# Never reboots, never touches system partitions; only writes under /userdata/e1sync.

BASE=/userdata/e1sync
STATE=$BASE/state
LOG=$BASE/log/e1sync.log
MIN_VALID=1735689600          # 2025-01-01, anything earlier is a reset clock
RESYNC_EVERY=21600            # re-sync at most every 6 h while online
HEARTBEAT_EVERY=1800          # save "last good time" every 30 min
mkdir -p $STATE $BASE/log
PIDF=/tmp/e1sync.pid          # tmpfs: cleared on every boot
if [ -f $PIDF ] && kill -0 "$(cat $PIDF)" 2>/dev/null; then exit 0; fi
echo $$ > $PIDF

log() {
  [ -f $LOG ] && [ $(wc -c < $LOG) -gt 200000 ] && mv -f $LOG $LOG.1
  echo "$(date '+%F %T') [$(cut -d' ' -f1 /proc/uptime)] $*" >> $LOG
}
now() { date +%s; }
uptime_s() { cut -d. -f1 /proc/uptime; }
set_status() { echo "$1" > $STATE/clock_status; }
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)

# ---- at boot: is the hardware clock still believable? ----
log "start boot_id=$BOOT_ID rtc=$(hwclock -r -u 2>/dev/null)"
LAST_GOOD=$(cat $STATE/last_good 2>/dev/null || echo 0)
if [ $(now) -lt $MIN_VALID ] || [ $(now) -lt $LAST_GOOD ]; then
  OLD=$(now)
  if [ $LAST_GOOD -gt $MIN_VALID ]; then
    date -s "@$LAST_GOOD" >/dev/null 2>&1
    log "clock looked reset ($OLD); restored last good time $LAST_GOOD (estimate)"
  else
    log "clock looked reset ($OLD) and no last good time saved"
  fi
  echo "$BOOT_ID estimated $OLD $(now)" >> $STATE/clock_steps
  set_status estimated
else
  set_status rtc_ok
fi
LAST_SYNC=0
LAST_BEAT=0

# Any clock step (ours, the vendor's ntpd, or manual) shows up as a change of
# "wall clock minus uptime". Log every step so recordings made earlier in the same
# boot can be shifted by the same amount later.
BASE_EPOCH=$(( $(now) - $(uptime_s) ))
check_jump() {
  NB=$(( $(now) - $(uptime_s) ))
  D=$(( NB - BASE_EPOCH ))
  if [ ${D#-} -gt 2 ]; then
    log "clock stepped by ${D}s"
    echo "$BOOT_ID step $D $(now)" >> $STATE/clock_steps
    BASE_EPOCH=$NB
  fi
}

wifi_up() { wpa_cli -i wlan0 status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; }

try_sync() {
  pidof ntpd >/dev/null && { log "ntpd already running, wait"; return 1; }
  ntpd -gq >/dev/null 2>&1 &
  PID=$!
  i=0
  while kill -0 $PID 2>/dev/null; do
    i=$((i+1)); [ $i -ge 60 ] && { kill $PID 2>/dev/null; log "ntpd timed out"; return 1; }
    sleep 1
  done
  wait $PID; RC=$?
  [ $RC -ne 0 ] && { log "ntpd failed rc=$RC"; return 1; }
  AFTER=$(now)
  check_jump
  hwclock -w -u && log "synced via ntp, hardware clock updated"
  echo "$BOOT_ID synced 0 $AFTER" >> $STATE/clock_steps
  echo $AFTER > $STATE/last_good
  echo $AFTER > $STATE/last_sync
  set_status synced
  return 0
}

while true; do
  check_jump
  T=$(now)
  if wifi_up && [ $((T - LAST_SYNC)) -ge $RESYNC_EVERY ]; then
    try_sync && LAST_SYNC=$(now)
  fi
  ST=$(cat $STATE/clock_status)
  if [ "$ST" != estimated ] && [ $((T - LAST_BEAT)) -ge $HEARTBEAT_EVERY ]; then
    echo $T > $STATE/last_good; LAST_BEAT=$T
  fi
  sleep 60
done
