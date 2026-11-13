// e1wifi runs on the Sogou E1 recorder (Buildroot, aarch64) and turns it into a WiFi uploader:
// whenever the pen is on WiFi with a valid clock, new recordings go to the owner's own Aliyun OSS bucket,
// and a small heartbeat tells the Mac app the pen's state. The pen's own database is only read, through the
// pen's /usr/bin/sqlite3; nothing outside /userdata/e1wifi is written.
//
// Files (all under /userdata/e1wifi):
//
//	e1wifi            this program
//	config.json       bucket, endpoint and an upload-only AccessKey (written by the Mac app over USB)
//	state/uploaded    one line per recording already uploaded
//	log               plain-text log, trimmed at 256 KB
//
// Bucket layout:
//
//	pen/<SN>/status.json                     heartbeat
//	pen/<SN>/rec/<name>/audio.wav            original recording
//	pen/<SN>/rec/<name>/listen.mp3           denoised copy for listening (if the pen made one)
//	pen/<SN>/rec/<name>/meta.json            title, time, duration, M-key marks — written last, marks "complete"
package main

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const version = "1.2.2"

type Config struct {
	Endpoint       string `json:"endpoint"`
	Bucket         string `json:"bucket"`
	KeyID          string `json:"keyId"`
	KeySecret      string `json:"keySecret"`
	MinDurationSec int    `json:"minDurationSec"`
	IntervalSec    int    `json:"intervalSec"`
	HeartbeatSec   int    `json:"heartbeatSec"`
}

type Recording struct {
	ID          int      `json:"recordId"`
	Type        string   `json:"type"`
	Title       string   `json:"title"`
	Created     string   `json:"created"`
	DurationSec int      `json:"durationSec"`
	Marks       []int    `json:"marks"`
	WavPath     string   `json:"wavPath"`
	Mp3Path     string   `json:"mp3Path,omitempty"`
	BSSIDs      []string `json:"bssids,omitempty"` // WiFi heard while recording, strongest first (for the place)
	UploadedAt  string   `json:"uploadedAt,omitempty"`
}

var (
	home    = env("E1WIFI_HOME", "/userdata/e1wifi")
	dbPath  = env("E1WIFI_DB", "/userdata/databases/E1-DATA.db")
	root    = env("E1WIFI_ROOT", "") // test hook: prefix for /mnt/sdcard paths
	once    = os.Getenv("E1WIFI_ONCE") != ""
	cfg     Config
	sn      string
	logFile *os.File
	logMu   sync.Mutex
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	os.MkdirAll(path.Join(home, "state"), 0o755)
	logFile, _ = os.OpenFile(path.Join(home, "log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if !singleInstance() {
		return
	}
	data, err := os.ReadFile(path.Join(home, "config.json"))
	if err != nil || json.Unmarshal(data, &cfg) != nil || cfg.Bucket == "" || cfg.KeyID == "" {
		logf("no usable config.json, exiting")
		return
	}
	if cfg.IntervalSec <= 0 {
		cfg.IntervalSec = 60
	}
	if cfg.HeartbeatSec <= 0 {
		cfg.HeartbeatSec = 120
	}
	sn = serial()
	logf("e1wifi %s started, sn=%s bucket=%s", version, sn, cfg.Bucket)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)

	// Cheap checks every 5 s and uploads every IntervalSec in this loop. The heartbeat (every HeartbeatSec, and
	// right away when WiFi comes up, the screen turns on, or something was uploaded) runs on its own goroutine,
	// so a long upload never silences it: the Mac shows the pen offline after two missed beats.
	beatNow := make(chan struct{}, 1)
	poke := func() {
		select {
		case beatNow <- struct{}{}:
		default:
		}
	}
	if !once {
		go func() {
			every := time.Duration(cfg.HeartbeatSec) * time.Second
			var lastBeat time.Time
			for {
				select {
				case <-beatNow:
				case <-time.After(5 * time.Second):
					if time.Since(lastBeat) < every {
						continue
					}
				}
				if !online() {
					continue
				}
				if err := heartbeat(); err != nil {
					logf("heartbeat: %v", err)
					lastBeat = time.Now().Add(30*time.Second - every) // try again in 30 s, not every 5 s
				} else {
					lastBeat = time.Now()
				}
			}
		}()
	}

	var lastScan time.Time
	lastState, lastScreen := "", screenOn()
	lastTick := time.Now()
	for {
		state := "ready"
		if !online() {
			state = "offline"
		}
		screen := screenOn()
		urgent := false
		// The pen suspends to RAM a few minutes after the screen goes dark, freezing this process. The wall clock
		// keeps running through a suspend while Go's monotonic clock doesn't, so a gap between the two means we
		// just woke up: beat and scan right away, and drop connections that died while asleep. (A clock being
		// set also opens a gap; one extra beat is harmless.)
		t := time.Now()
		if gap := t.Round(0).Sub(lastTick.Round(0)) - t.Sub(lastTick); gap > 20*time.Second || gap < -20*time.Second {
			logf("woke up (asleep about %v)", gap.Round(time.Second))
			client.CloseIdleConnections()
			urgent = true
		}
		lastTick = t
		if state != lastState {
			logf("state: %s", state)
			urgent = state == "ready"
			lastState = state
		}
		if screen != lastScreen {
			if screen == "on" {
				urgent = true
			}
			lastScreen = screen
		}
		if urgent {
			poke() // the beat goes out first, before any upload
		}
		if state == "ready" {
			if urgent || time.Since(lastScan) >= time.Duration(cfg.IntervalSec)*time.Second {
				if uploadNew() > 0 {
					poke()
				}
				lastScan = time.Now()
			}
			if once {
				if err := heartbeat(); err != nil {
					logf("heartbeat: %v", err)
				}
			}
		}
		if once {
			return
		}
		select {
		case <-stop:
			logf("stopped")
			return
		case <-time.After(5 * time.Second):
		}
	}
}

// screenOn reports "on", "off" or "" (unknown) from the backlight.
func screenOn() string {
	if dirs, _ := os.ReadDir("/sys/class/backlight"); len(dirs) > 0 {
		base := "/sys/class/backlight/" + dirs[0].Name()
		if p := readTrim(base + "/bl_power"); p != "" && p != "0" {
			return "off"
		}
		if b := readTrim(base + "/brightness"); b != "" {
			if b == "0" {
				return "off"
			}
			return "on"
		}
	}
	if b := readTrim("/sys/class/graphics/fb0/blank"); b != "" {
		if b == "0" {
			return "on"
		}
		return "off"
	}
	return ""
}

// ---------- pen state ----------

func serial() string {
	if s := os.Getenv("E1WIFI_SN"); s != "" {
		return s
	}
	b, _ := os.ReadFile("/proc/cmdline")
	for _, f := range strings.Fields(string(b)) {
		if strings.HasPrefix(f, "androidboot.serialno=") {
			return strings.TrimPrefix(f, "androidboot.serialno=")
		}
	}
	return "unknown"
}

// wpaCli finds wpa_cli even when started from the boot hook with a minimal PATH.
func wpaCli() string {
	for _, p := range []string{"/usr/sbin/wpa_cli", "/sbin/wpa_cli", "/usr/bin/wpa_cli", "/bin/wpa_cli"} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "wpa_cli"
}

func online() bool {
	if os.Getenv("E1WIFI_FORCE_ONLINE") != "" {
		return true
	}
	out, err := exec.Command(wpaCli(), "status").Output()
	if err != nil {
		// can't ask wpa_supplicant: assume online and let the upload itself tell us
		return true
	}
	return strings.Contains(string(out), "wpa_state=COMPLETED")
}

func ssid() string { return wpaField("ssid") }

func wpaField(name string) string {
	out, _ := exec.Command(wpaCli(), "status").Output()
	for _, l := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(l, name+"=") {
			return strings.TrimPrefix(l, name+"=")
		}
	}
	return ""
}

// OSS rejects requests whose Date is more than 15 minutes off. Rather than wait for the pen's clock to be
// set, every OSS reply carries the server's time; a pen clock that is off is corrected for when signing.
var (
	skewMu sync.Mutex
	skew   time.Duration // OSS time minus this pen's clock (0 while the clock is within 2 minutes)
)

func now() time.Time {
	skewMu.Lock()
	defer skewMu.Unlock()
	return time.Now().Add(skew)
}

func learnSkew(resp *http.Response) {
	t, err := http.ParseTime(resp.Header.Get("Date"))
	if err != nil {
		return
	}
	d := time.Until(t)
	if d < 2*time.Minute && d > -2*time.Minute {
		d = 0
	}
	skewMu.Lock()
	changed := d != skew
	skew = d
	skewMu.Unlock()
	if changed {
		logf("pen clock is off by %v; correcting for it when talking to OSS", d.Round(time.Second))
	}
}

func readTrim(p string) string {
	b, _ := os.ReadFile(p)
	return strings.TrimSpace(string(b))
}

func battery() (int, bool) {
	n, _ := strconv.Atoi(readTrim("/sys/class/power_supply/battery/capacity"))
	st := readTrim("/sys/class/power_supply/battery/status")
	return n, st == "Charging" || st == "Full"
}

func freeBytes() int64 {
	var s syscall.Statfs_t
	if syscall.Statfs(local("/mnt/sdcard"), &s) != nil {
		return -1
	}
	return int64(s.Bavail) * int64(s.Bsize)
}

func local(p string) string {
	if strings.HasPrefix(p, "/sdcard/") {
		p = "/mnt" + p
	}
	return root + p
}

var (
	recsMu   sync.Mutex
	recsAt   time.Time
	recsLast []Recording
)

// recordingsFresh reuses a read from the last maxAge instead of querying the database the pen's own app is
// writing to again (the heartbeat rides on the upload scan's read).
func recordingsFresh(maxAge time.Duration) ([]Recording, error) {
	recsMu.Lock()
	if recsLast != nil && time.Since(recsAt) < maxAge {
		r := recsLast
		recsMu.Unlock()
		return r, nil
	}
	recsMu.Unlock()
	r, err := recordings()
	if err == nil {
		recsMu.Lock()
		recsLast, recsAt = r, time.Now()
		recsMu.Unlock()
	}
	return r, err
}

// recordings reads the pen's database through its own sqlite3 (read-only query).
func recordings() ([]Recording, error) {
	sep := "\x1f"
	q := "SELECT id, recordTypeName, titleName, createTime, replace(replace(ifnull(aiTagData,''), char(10), ''), char(13), ''), " +
		"waveFormDuration, waveFormPath, ifnull(playbackPath,''), replace(replace(ifnull(locationWifiList,''), char(10), ''), char(13), '') FROM record_table WHERE recordType != 8 AND waveFormPath LIKE '%.wav' ORDER BY id"
	out, err := exec.Command(env("E1WIFI_SQLITE", "/usr/bin/sqlite3"), "-readonly", "-cmd", ".timeout 5000", "-separator", sep, dbPath, q).Output()
	if err != nil {
		return nil, fmt.Errorf("sqlite3: %v", err)
	}
	var recs []Recording
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		f := strings.Split(sc.Text(), sep)
		if len(f) < 9 {
			continue
		}
		id, _ := strconv.Atoi(f[0])
		dur, _ := strconv.Atoi(f[5])
		r := Recording{ID: id, Type: f[1], Title: f[2], DurationSec: dur, WavPath: local2pen(f[6]), Mp3Path: local2pen(f[7])}
		if t, err := time.ParseInLocation("2006:01:02 15:04:05", f[3], time.FixedZone("CST", 8*3600)); err == nil {
			r.Created = t.Format(time.RFC3339)
		}
		r.BSSIDs = wifiList(f[8])
		var tags []string
		json.Unmarshal([]byte(f[4]), &tags)
		for _, t := range tags {
			if n, err := strconv.Atoi(strings.TrimSuffix(strings.TrimSpace(t), "s")); err == nil {
				r.Marks = append(r.Marks, n)
			}
		}
		recs = append(recs, r)
	}
	return recs, nil
}

// wifiList turns ["aa:bb:cc:dd:ee:ff/-42", ...] into BSSIDs, strongest first.
func wifiList(s string) []string {
	var items []string
	json.Unmarshal([]byte(s), &items)
	type ap struct {
		mac  string
		rssi int
	}
	var aps []ap
	for _, it := range items {
		parts := strings.Split(strings.TrimSpace(it), "/")
		if len(parts) != 2 {
			continue
		}
		n, err := strconv.Atoi(parts[1])
		if err != nil {
			continue
		}
		aps = append(aps, ap{strings.ToLower(parts[0]), n})
	}
	for i := 1; i < len(aps); i++ {
		for j := i; j > 0 && aps[j].rssi > aps[j-1].rssi; j-- {
			aps[j], aps[j-1] = aps[j-1], aps[j]
		}
	}
	out := []string{}
	for _, a := range aps {
		out = append(out, a.mac)
	}
	return out
}

func local2pen(p string) string {
	if strings.HasPrefix(p, "/sdcard/") {
		return "/mnt" + p
	}
	return p
}

// ---------- upload state ----------

func uploadedSet() map[string]bool {
	m := map[string]bool{}
	b, _ := os.ReadFile(path.Join(home, "state", "uploaded"))
	for _, l := range strings.Split(string(b), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			m[l] = true
		}
	}
	return m
}

func markUploaded(wav string) {
	f, err := os.OpenFile(path.Join(home, "state", "uploaded"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err == nil {
		fmt.Fprintln(f, wav)
		f.Close()
	}
}

func uploadNew() int {
	recs, err := recordingsFresh(0)
	if err != nil {
		logf("%v", err)
		return 0
	}
	if b, charging := battery(); b > 0 && b < 15 && !charging {
		return 0 // keep the battery for recording
	}
	if recordingBusy(recs) {
		return 0 // never compete with a recording in progress for the SD card or CPU; go on once it's saved
	}
	done := uploadedSet()
	n := 0
	for _, r := range recs {
		// Duration 0 = still being recorded: the pen adds the row when recording starts and fills in the length on save.
		if done[r.WavPath] || r.DurationSec <= 0 || r.DurationSec < cfg.MinDurationSec {
			continue
		}
		st, err := os.Stat(local(r.WavPath))
		if err != nil || time.Since(st.ModTime()) < time.Minute {
			continue // missing, or still being written
		}
		base := strings.TrimSuffix(path.Base(r.WavPath), ".wav")
		dir := fmt.Sprintf("pen/%s/rec/%s/", sn, base)
		if err := putFile(dir+"audio.wav", local(r.WavPath), "audio/wav"); err != nil {
			logf("upload %s: %v", r.Title, err)
			continue
		}
		if r.Mp3Path != "" {
			if _, err := os.Stat(local(r.Mp3Path)); err == nil {
				if err := putFile(dir+"listen.mp3", local(r.Mp3Path), "audio/mpeg"); err != nil {
					logf("upload mp3 %s: %v", r.Title, err)
				}
			}
		}
		r.UploadedAt = now().Format(time.RFC3339)
		meta, _ := json.MarshalIndent(r, "", "  ")
		if err := putBytes(dir+"meta.json", meta, "application/json"); err != nil {
			logf("upload meta %s: %v", r.Title, err)
			continue
		}
		markUploaded(r.WavPath)
		logf("uploaded %s (%ds)", r.Title, r.DurationSec)
		n++
	}
	return n
}

// recordingBusy: some .wav in the recordings folders was written within the last minute, i.e. the pen is
// recording (or just saving) right now.
func recordingBusy(recs []Recording) bool {
	dirs := map[string]bool{}
	for _, r := range recs {
		dirs[path.Dir(local(r.WavPath))] = true
	}
	for d := range dirs {
		entries, _ := os.ReadDir(d)
		for _, e := range entries {
			if !strings.HasSuffix(strings.ToLower(e.Name()), ".wav") {
				continue
			}
			if info, err := e.Info(); err == nil && time.Since(info.ModTime()) < time.Minute {
				return true
			}
		}
	}
	return false
}

func heartbeat() error {
	recs, _ := recordingsFresh(90 * time.Second)
	if len(recs) > 100 {
		recs = recs[len(recs)-100:] // the latest 100 are plenty for the Mac's list; keeps the beat small
	}
	done := uploadedSet()
	type item struct {
		WavPath     string `json:"wavPath"`
		Title       string `json:"title"`
		Created     string `json:"created"`
		DurationSec int    `json:"durationSec"`
		Uploaded    bool   `json:"uploaded"`
	}
	list := []item{}
	for _, r := range recs {
		list = append(list, item{r.WavPath, r.Title, r.Created, r.DurationSec, done[r.WavPath]})
	}
	b, charging := battery()
	status := map[string]any{
		"sn": sn, "version": version, "time": now().Format(time.RFC3339),
		"battery": b, "charging": charging, "freeBytes": freeBytes(), "ssid": ssid(), "bssid": strings.ToLower(wpaField("bssid")),
		"clockStatus": readTrim("/userdata/e1sync/state/clock_status"),
		"firmware":    firmware(), "recordings": list, "heartbeatSec": cfg.HeartbeatSec,
	}
	data, _ := json.MarshalIndent(status, "", "  ")
	return putBytes(fmt.Sprintf("pen/%s/status.json", sn), data, "application/json")
}

func firmware() string {
	b, _ := os.ReadFile("/etc/sogou/system_version.info")
	var v map[string]any
	if json.Unmarshal(b, &v) == nil {
		if s, ok := v["system_version"].(string); ok {
			return s
		}
	}
	return ""
}

// ---------- OSS (PutObject, signature V1) ----------

// No fixed overall timeout (a long recording on slow WiFi can take a while); instead a request is dropped when
// it stops making progress — e.g. WiFi went away or the pen slept mid-upload.
var client = &http.Client{Transport: &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	DialContext:           (&net.Dialer{Timeout: 20 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
	TLSHandshakeTimeout:   20 * time.Second,
	ResponseHeaderTimeout: 2 * time.Minute,
	IdleConnTimeout:       90 * time.Second,
}}

var stallLimit = 90 * time.Second // var so tests can shorten it

// progressReader remembers when the request body was last read, i.e. when bytes last went out.
type progressReader struct {
	r    io.Reader
	mu   sync.Mutex
	last time.Time
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	if n > 0 {
		p.mu.Lock()
		p.last = time.Now()
		p.mu.Unlock()
	}
	return n, err
}

func (p *progressReader) idle() time.Duration {
	p.mu.Lock()
	defer p.mu.Unlock()
	return time.Since(p.last)
}

func putFile(key, file, ctype string) error {
	f, err := os.Open(file)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	return put(key, f, st.Size(), ctype)
}

func putBytes(key string, data []byte, ctype string) error {
	return put(key, strings.NewReader(string(data)), int64(len(data)), ctype)
}

func put(key string, body io.ReadSeeker, size int64, ctype string) error {
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt*10) * time.Second)
		}
		if _, err := body.Seek(0, io.SeekStart); err != nil {
			return err
		}
		err := putOnce(key, body, size, ctype)
		if err == nil {
			return nil
		}
		last = err
		if he, ok := err.(httpError); ok && he.code == 403 && !strings.Contains(he.msg, "RequestTimeTooSkewed") {
			return last // wrong key or permission: retrying won't help (a clock error is corrected by now)
		}
	}
	return last
}

type httpError struct {
	code int
	msg  string
}

func (e httpError) Error() string { return fmt.Sprintf("HTTP %d: %s", e.code, e.msg) }

func putOnce(key string, body io.Reader, size int64, ctype string) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pr := &progressReader{r: body, last: time.Now()}
	done := make(chan struct{})
	defer close(done)
	go func() { // stall watchdog
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				if pr.idle() > stallLimit {
					cancel()
					return
				}
			}
		}
	}()

	url := fmt.Sprintf("https://%s.%s/%s", cfg.Bucket, cfg.Endpoint, key)
	req, err := http.NewRequestWithContext(ctx, "PUT", url, pr)
	if err != nil {
		return err
	}
	req.ContentLength = size
	date := now().UTC().Format(http.TimeFormat)
	mac := hmac.New(sha1.New, []byte(cfg.KeySecret))
	fmt.Fprintf(mac, "PUT\n\n%s\n%s\n/%s/%s", ctype, date, cfg.Bucket, key)
	req.Header.Set("Content-Type", ctype)
	req.Header.Set("Date", date)
	req.Header.Set("Authorization", "OSS "+cfg.KeyID+":"+base64.StdEncoding.EncodeToString(mac.Sum(nil)))
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("no progress for %v, gave up", stallLimit)
		}
		return err
	}
	learnSkew(resp)
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
	resp.Body.Close()
	if resp.StatusCode == 200 {
		return nil
	}
	return httpError{resp.StatusCode, strings.TrimSpace(string(msg))}
}

// ---------- housekeeping ----------

func singleInstance() bool {
	pidFile := env("E1WIFI_PIDFILE", "/tmp/e1wifi.pid")
	if b, err := os.ReadFile(pidFile); err == nil {
		if pid, _ := strconv.Atoi(strings.TrimSpace(string(b))); pid > 0 && syscall.Kill(pid, 0) == nil {
			if cmd, _ := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid)); strings.Contains(string(cmd), "e1wifi") {
				return false
			}
		}
	}
	os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())), 0o644)
	return true
}

func logf(format string, a ...any) {
	if logFile == nil {
		return
	}
	logMu.Lock()
	defer logMu.Unlock()
	if st, err := logFile.Stat(); err == nil && st.Size() > 256*1024 {
		logFile.Truncate(0)
		logFile.Seek(0, io.SeekStart)
	}
	fmt.Fprintf(logFile, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, a...))
}
