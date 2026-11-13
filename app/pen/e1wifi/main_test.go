package main

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeOSS points the uploader's HTTP client at a local TLS server, whatever host name it asks for.
func fakeOSS(t *testing.T, h http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewTLSServer(h)
	t.Cleanup(srv.Close)
	addr := srv.Listener.Addr().String()
	old := client
	client = &http.Client{Transport: &http.Transport{
		TLSClientConfig:       &tls.Config{InsecureSkipVerify: true},
		ResponseHeaderTimeout: 10 * time.Second,
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
	}}
	t.Cleanup(func() { client = old })
	cfg = Config{Endpoint: "oss.test", Bucket: "b", KeyID: "id", KeySecret: "secret"}
	skew = 0
}

func TestPutUploadsWholeBody(t *testing.T) {
	var got int64
	fakeOSS(t, func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "OSS id:") || r.Method != "PUT" {
			w.WriteHeader(403)
			return
		}
		n, _ := io.Copy(io.Discard, r.Body)
		atomic.StoreInt64(&got, n)
	})
	data := strings.Repeat("x", 3<<20)
	if err := putBytes("pen/T/rec/a/audio.wav", []byte(data), "audio/wav"); err != nil {
		t.Fatal(err)
	}
	if got != int64(len(data)) {
		t.Fatalf("server got %d bytes, want %d", got, len(data))
	}
}

// The pen's clock is an hour behind: OSS refuses the first request, the reply's Date teaches the offset, and the
// retry goes through. Later requests are signed with the corrected time straight away.
func TestClockOffsetIsLearned(t *testing.T) {
	serverNow := func() time.Time { return time.Now().Add(time.Hour) }
	var calls int32
	fakeOSS(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.Header().Set("Date", serverNow().UTC().Format(http.TimeFormat))
		d, err := http.ParseTime(r.Header.Get("Date"))
		if err != nil || serverNow().Sub(d) > 15*time.Minute || d.Sub(serverNow()) > 15*time.Minute {
			w.WriteHeader(403)
			io.WriteString(w, "<Code>RequestTimeTooSkewed</Code>")
			return
		}
		io.Copy(io.Discard, r.Body)
	})
	if err := putBytes("k", []byte("hi"), "text/plain"); err != nil {
		t.Fatalf("upload with a wrong clock: %v", err)
	}
	if n := atomic.LoadInt32(&calls); n != 2 {
		t.Fatalf("calls = %d, want 2 (refused once, then accepted)", n)
	}
	if skew < 59*time.Minute || skew > 61*time.Minute {
		t.Fatalf("learned skew %v, want about 1h", skew)
	}
	atomic.StoreInt32(&calls, 0)
	if err := putBytes("k2", []byte("hi"), "text/plain"); err != nil || atomic.LoadInt32(&calls) != 1 {
		t.Fatalf("second upload: err=%v calls=%d, want first-time success", err, calls)
	}
}

// A wrong key is not retried (no point hammering OSS).
func TestForbiddenIsNotRetried(t *testing.T) {
	var calls int32
	fakeOSS(t, func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(403)
		io.WriteString(w, "<Code>AccessDenied</Code>")
	})
	if err := putBytes("k", []byte("hi"), "text/plain"); err == nil {
		t.Fatal("want an error")
	}
	if calls != 1 {
		t.Fatalf("calls = %d, want 1", calls)
	}
}

// The connection goes dead mid-upload (server stops reading): the upload gives up after the stall limit instead
// of hanging for half an hour.
func TestStalledUploadGivesUp(t *testing.T) {
	stallLimit = 2 * time.Second
	defer func() { stallLimit = 90 * time.Second }()
	release := make(chan struct{})
	fakeOSS(t, func(w http.ResponseWriter, r *http.Request) {
		io.CopyN(io.Discard, r.Body, 1<<20) // take 1 MB, then stop reading
		<-release
	})
	defer close(release)
	start := time.Now()
	err := putOnce("k", strings.NewReader(strings.Repeat("x", 64<<20)), 64<<20, "audio/wav")
	if err == nil || !strings.Contains(err.Error(), "no progress") {
		t.Fatalf("err = %v, want a stall error", err)
	}
	if d := time.Since(start); d > 15*time.Second {
		t.Fatalf("took %v to give up", d)
	}
}

func TestRecordingBusy(t *testing.T) {
	dir := t.TempDir()
	done := filepath.Join(dir, "20260101090000_meeting.wav")
	os.WriteFile(done, []byte("x"), 0o644)
	old := time.Now().Add(-10 * time.Minute)
	os.Chtimes(done, old, old)
	recs := []Recording{{WavPath: done}}
	if recordingBusy(recs) {
		t.Fatal("busy with only an old recording")
	}
	live := filepath.Join(dir, "20260101100000_meeting.wav") // not in the database yet: being recorded
	os.WriteFile(live, []byte("x"), 0o644)
	if !recordingBusy(recs) {
		t.Fatal("not busy while a new .wav is being written")
	}
}
