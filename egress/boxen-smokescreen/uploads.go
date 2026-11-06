// egress/boxen-smokescreen/uploads.go
// The upload watch: an early warning for bulk uploads to an allowed host. The
// proxy can't see what a tunnel carries, but it sees how much. For each
// CONNECT host it counts the bytes the client sends, across every tunnel of
// this proxy process, over the trailing hour (in one-minute slots). The first
// time a host goes over its limit, it writes one log line; it writes no
// other for that host until an hour has passed.
//
// With the cap on (and the mode enforce), a write that would take a host over
// its limit fails instead, which closes its tunnel, and so does every write
// to that host until enough of the hour's bytes have aged out.
//
// The counts live in memory: a new generation starts from zero, and a
// draining one keeps its own.
//
// boxen-proxy-run sets BOXEN_UPLOAD_LIMITS to the generation's limits file,
// one "<host>|*.<domain>|default <bytes>|off" per line, and BOXEN_UPLOAD_CAP
// to on or off.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sirupsen/logrus"
)

// The one log line for a host over its limit; boxen-egress-ctl looks for it.
const uploadMessage = "BOXEN-UPLOAD-LIMIT"

const uploadSlots = 60 // one per minute of the hour

// Hosts with nothing in the window are dropped once there are this many.
const uploadMaxHosts = 10000

var errUploadCut = errors.New("boxen: tunnel closed by the upload cap")

type uploadWatch struct {
	limits map[string]int64 // host, "*.domain" or "default"; 0 is off
	cut    bool
	now    func() time.Time
	log    *logrus.Logger

	mu    sync.Mutex
	hosts map[string]*hostUploads
}

// One host's bytes per minute, in a ring indexed by Unix minute.
type hostUploads struct {
	minute [uploadSlots]int64
	bytes  [uploadSlots]int64
	quiet  time.Time // no other log line before this
}

// uploadWatchFromEnv reads the limits and the cap that boxen-proxy-run sets.
// It returns nil when there are no limits, so nothing is counted. The caller
// sets its logger.
func uploadWatchFromEnv(enforce bool) (*uploadWatch, error) {
	capped := os.Getenv("BOXEN_UPLOAD_CAP")
	if capped != "" && capped != "on" && capped != "off" {
		return nil, fmt.Errorf("BOXEN_UPLOAD_CAP must be on or off, not %q", capped)
	}
	path := os.Getenv("BOXEN_UPLOAD_LIMITS")
	if path == "" {
		return nil, nil
	}
	limits, err := readUploadLimits(path)
	if err != nil {
		return nil, err
	}
	return newUploadWatch(limits, enforce && capped == "on", time.Now, nil), nil
}

func newUploadWatch(limits map[string]int64, cut bool, now func() time.Time, logger *logrus.Logger) *uploadWatch {
	return &uploadWatch{limits: limits, cut: cut, now: now, log: logger, hosts: map[string]*hostUploads{}}
}

func readUploadLimits(path string) (map[string]int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	limits := map[string]int64{}
	s := bufio.NewScanner(f)
	for line := 1; s.Scan(); line++ {
		w := strings.Fields(s.Text())
		if len(w) == 0 {
			continue
		}
		n, err := strconv.ParseInt(w[len(w)-1], 10, 64)
		if w[len(w)-1] == "off" {
			n, err = 0, nil
		}
		if len(w) != 2 || err != nil || n < 0 {
			return nil, fmt.Errorf("%s line %d: want <host> <bytes>|off", path, line)
		}
		limits[w[0]] = n
	}
	return limits, s.Err()
}

// limitFor is host's limit: its own entry, else the longest wildcard that
// covers it (a wildcard covers subdomains, not the name itself, as in the
// allowlist), else the default. 0 means no limit.
func (w *uploadWatch) limitFor(host string) int64 {
	if n, ok := w.limits[host]; ok {
		return n
	}
	for d := host; strings.Contains(d, "."); {
		d = d[strings.Index(d, ".")+1:]
		if n, ok := w.limits["*."+d]; ok {
			return n
		}
	}
	return w.limits["default"]
}

// add decides on n more bytes for host. It counts them and returns nil, or,
// when the cap is on and they would take host over its limit, counts nothing
// and returns an error.
func (w *uploadWatch) add(host string, port, n int) error {
	limit := w.limitFor(host)
	if limit == 0 {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	now := w.now()
	m := now.Unix() / 60
	h := w.hosts[host]
	if h == nil {
		if len(w.hosts) >= uploadMaxHosts {
			w.prune(now, m)
		}
		h = &hostUploads{}
		w.hosts[host] = h
	}
	sent := h.sent(m)
	if sent+int64(n) <= limit {
		h.count(m, int64(n))
		return nil
	}
	if w.cut {
		w.report(h, now, host, port, sent, limit)
		return errUploadCut
	}
	h.count(m, int64(n))
	w.report(h, now, host, port, sent+int64(n), limit)
	return nil
}

// report writes the host's log line, at most once an hour: the host, what it
// was sent in the hour, its limit and whether the tunnel was cut. Never bytes
// of the stream.
func (w *uploadWatch) report(h *hostUploads, now time.Time, host string, port int, sent, limit int64) {
	if now.Before(h.quiet) {
		return
	}
	h.quiet = now.Add(uploadSlots * time.Minute)
	w.log.WithFields(logrus.Fields{
		"connect_host": printable(host),
		"connect_port": port,
		"window_bytes": sent,
		"limit_bytes":  limit,
		"cut":          w.cut,
	}).Warn(uploadMessage)
}

// sent is the host's total for the hour up to minute m.
func (h *hostUploads) sent(m int64) int64 {
	var t int64
	for i := range h.bytes {
		if h.minute[i] > m-uploadSlots {
			t += h.bytes[i]
		}
	}
	return t
}

func (h *hostUploads) count(m, n int64) {
	i := m % uploadSlots
	if h.minute[i] != m {
		h.minute[i], h.bytes[i] = m, 0
	}
	h.bytes[i] += n
}

// prune drops hosts with nothing in the hour and no log line to hold back.
func (w *uploadWatch) prune(now time.Time, m int64) {
	for host, h := range w.hosts {
		if h.sent(m) == 0 && !now.Before(h.quiet) {
			delete(w.hosts, host)
		}
	}
}

// countedConn passes each write the client sends through the watch.
type countedConn struct {
	net.Conn
	host  string
	port  int
	watch *uploadWatch
}

func (c *countedConn) Write(b []byte) (int, error) {
	if err := c.watch.add(c.host, c.port, len(b)); err != nil {
		return 0, err
	}
	return c.Conn.Write(b)
}
