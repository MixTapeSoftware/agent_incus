// egress/boxen-smokescreen/main_test.go
// The TLS name check, in process: real ClientHellos from crypto/tls, sent
// through the dial hook to a loopback listener, and once through smokescreen
// itself. Copy both files into smokescreen's tree as build-smokescreen.sh
// does, and run go test ./cmd/boxen-smokescreen/ with its flags.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/stripe/goproxy"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	"github.com/stripe/smokescreen/pkg/smokescreen/conntrack"
	"github.com/stripe/smokescreen/pkg/smokescreen/metrics"
)

// hello is the first record a TLS client sends for serverName.
func hello(t *testing.T, serverName string) []byte {
	t.Helper()
	client, server := net.Pipe()
	defer server.Close()
	go tls.Client(client, &tls.Config{ServerName: serverName, InsecureSkipVerify: true}).Handshake()
	head := make([]byte, 5)
	if _, err := io.ReadFull(server, head); err != nil {
		t.Fatal(err)
	}
	body := make([]byte, int(head[3])<<8|int(head[4]))
	if _, err := io.ReadFull(server, body); err != nil {
		t.Fatal(err)
	}
	client.Close()
	return append(head, body...)
}

// tunnel dials a loopback listener through the hook, as for a request for
// target, and returns the conn and what the listener receives once it closes.
func tunnel(t *testing.T, enforce bool, method, target string) (net.Conn, <-chan []byte, *bytes.Buffer) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	got := make(chan []byte, 1)
	go func() {
		c, err := l.Accept()
		if err != nil {
			got <- nil
			return
		}
		b, _ := io.ReadAll(c)
		got <- b
	}()
	logs := &bytes.Buffer{}
	logger := logrus.New()
	logger.Out = logs
	logger.Formatter = &logrus.JSONFormatter{}
	req := &http.Request{Method: method, Host: target, URL: &url.URL{Host: target}}
	ctx := context.WithValue(context.Background(), goproxy.ProxyContextKey, &goproxy.ProxyCtx{Req: req})
	mode := "report"
	if enforce {
		mode = "enforce"
	}
	conn, err := tunnelDialer(mode, nil, logger)(ctx, "tcp", l.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return conn, got, logs
}

// send writes each part, and returns the first error.
func send(conn net.Conn, parts ...[]byte) error {
	for _, p := range parts {
		if _, err := conn.Write(p); err != nil {
			return err
		}
	}
	return nil
}

func received(t *testing.T, conn net.Conn, got <-chan []byte) []byte {
	t.Helper()
	conn.Close()
	select {
	case b := <-got:
		return b
	case <-time.After(5 * time.Second):
		t.Fatal("the listener never finished")
		return nil
	}
}

// logLine is the one BOXEN-TLS-NAME-CHECK line, or fails.
func logLine(t *testing.T, logs *bytes.Buffer) map[string]interface{} {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	if len(lines) != 1 {
		t.Fatalf("want one log line, got %q", logs.String())
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(lines[0]), &m); err != nil {
		t.Fatal(err)
	}
	if m["msg"] != logMessage {
		t.Fatalf("msg = %v", m["msg"])
	}
	return m
}

func TestMatchingNamePassesIntact(t *testing.T) {
	h := hello(t, "allowed.example")
	conn, got, logs := tunnel(t, true, "CONNECT", "allowed.example:443")
	if err := send(conn, h, []byte("after")); err != nil {
		t.Fatal(err)
	}
	if b := received(t, conn, got); !bytes.Equal(b, append(h, "after"...)) {
		t.Fatalf("forwarded %d bytes, want %d", len(b), len(h)+5)
	}
	if logs.Len() != 0 {
		t.Fatalf("logged %q", logs.String())
	}
}

func TestSplitWrites(t *testing.T) {
	h := hello(t, "allowed.example")
	conn, got, _ := tunnel(t, true, "CONNECT", "allowed.example:443")
	if err := send(conn, h[:1], h[1:4], h[4:100], h[100:]); err != nil {
		t.Fatal(err)
	}
	if b := received(t, conn, got); !bytes.Equal(b, h) {
		t.Fatal("a ClientHello split across writes didn't arrive intact")
	}

	h = hello(t, "other.example")
	conn, got, logs := tunnel(t, true, "CONNECT", "allowed.example:443")
	if err := send(conn, h[:3], h[3:]); err == nil {
		t.Fatal("a split ClientHello for another name was let through")
	}
	if b := received(t, conn, got); len(b) != 0 {
		t.Fatalf("forwarded %d bytes", len(b))
	}
	logLine(t, logs)
}

func TestCaseAndTrailingDot(t *testing.T) {
	h := hello(t, "allowed.example")
	conn, got, _ := tunnel(t, true, "CONNECT", "Allowed.EXAMPLE.:443")
	if err := send(conn, h); err != nil {
		t.Fatal(err)
	}
	if b := received(t, conn, got); !bytes.Equal(b, h) {
		t.Fatal("case or a trailing dot made it refuse")
	}
}

func TestRefused(t *testing.T) {
	big := []byte{22, 3, 1, 0x40, 0x01} // a record body of 16385 bytes
	for _, tc := range []struct {
		what, reason, name string
		first              []byte
	}{
		{"another name", "mismatch", "other.example", hello(t, "other.example")},
		{"a longer name", "mismatch", "allowed.example.evil", hello(t, "allowed.example.evil")},
		{"no name", "no_name", "", hello(t, "")},
		{"plain HTTP", "not_tls", "", []byte("GET / HTTP/1.1\r\nHost: other.example\r\n\r\n")},
		{"a record too long for TLS", "malformed", "", big},
		{"a handshake record that isn't a ClientHello", "malformed", "", []byte{22, 3, 1, 0, 4, 2, 0, 0, 0}},
	} {
		t.Run(tc.what, func(t *testing.T) {
			conn, got, logs := tunnel(t, true, "CONNECT", "allowed.example:443")
			if err := send(conn, tc.first); err == nil {
				t.Fatal("let through")
			}
			if err := send(conn, []byte("more")); err == nil {
				t.Fatal("a later write went through")
			}
			if b := received(t, conn, got); len(b) != 0 {
				t.Fatalf("forwarded %d bytes", len(b))
			}
			m := logLine(t, logs)
			if m["reason"] != tc.reason || m["tls_name"] != tc.name || m["connect_host"] != "allowed.example" ||
				m["connect_port"] != float64(443) || m["enforced"] != true {
				t.Fatalf("log line %v", m)
			}
			if strings.Contains(logs.String(), "HTTP/1.1") {
				t.Fatal("stream bytes were logged")
			}
		})
	}
}

func TestReportModeForwardsAndLogs(t *testing.T) {
	h := hello(t, "other.example")
	conn, got, logs := tunnel(t, false, "CONNECT", "allowed.example:443")
	if err := send(conn, h[:10], h[10:], []byte("after")); err != nil {
		t.Fatal(err)
	}
	if b := received(t, conn, got); !bytes.Equal(b, append(h, "after"...)) {
		t.Fatal("report mode didn't forward intact")
	}
	if m := logLine(t, logs); m["reason"] != "mismatch" || m["tls_name"] != "other.example" || m["enforced"] != false {
		t.Fatalf("log line %v", m)
	}
}

func TestPlainHTTPUntouched(t *testing.T) {
	conn, got, logs := tunnel(t, true, "GET", "other.example:80")
	if _, ok := conn.(*checkedConn); ok {
		t.Fatal("a plain HTTP request's connection was wrapped")
	}
	if err := send(conn, []byte("GET / HTTP/1.1\r\n\r\n")); err != nil {
		t.Fatal(err)
	}
	if b := received(t, conn, got); string(b) != "GET / HTTP/1.1\r\n\r\n" || logs.Len() != 0 {
		t.Fatalf("got %q, logged %q", b, logs.String())
	}
}

func TestSameHostIsASCIIOnly(t *testing.T) {
	if !sameHost("Ab.example", "ab.example.") || sameHost("K.example", "k.example") || sameHost("", ".") {
		t.Fatal("sameHost")
	}
	if got := printable("a\x1b]0;x\x07bé"); got != "a?]0;x?b?" {
		t.Fatalf("printable = %q", got)
	}
}

// Through smokescreen itself: its CONNECT handling, InstrumentedConn and
// goproxy's copy, to a local TLS server.
func TestThroughSmokescreen(t *testing.T) {
	var hits int32
	site := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
	}))
	defer site.Close()
	_, port, _ := net.SplitHostPort(site.Listener.Addr().String())

	logs := &bytes.Buffer{}
	conf := smokescreen.NewConfig()
	conf.Log.Out = logs
	conf.Log.Formatter = &logrus.JSONFormatter{}
	conf.AllowMissingRole = true
	if err := conf.SetAllowAddresses([]string{"127.0.0.1"}); err != nil {
		t.Fatal(err)
	}
	conf.ConnTracker = conntrack.NewTracker(conf.IdleTimeout, metrics.NewNoOpMetricsClient(), conf.Log, atomic.Value{}, nil)
	conf.ProxyDialTimeout = tunnelDialer("enforce", nil, conf.Log)
	proxy := httptest.NewServer(smokescreen.BuildProxy(conf))
	defer proxy.Close()

	get := func(sni string) error {
		proxyURL, _ := url.Parse(proxy.URL)
		c := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
			Proxy:           http.ProxyURL(proxyURL),
			TLSClientConfig: &tls.Config{ServerName: sni, InsecureSkipVerify: true},
		}}
		resp, err := c.Get("https://localhost:" + port + "/")
		if err == nil {
			resp.Body.Close()
		}
		return err
	}
	if err := get("localhost"); err != nil {
		t.Fatalf("the matching name failed: %v", err)
	}
	if err := get("other.example"); err == nil {
		t.Fatal("another name got through smokescreen")
	}
	if atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("the site saw %d requests, want 1", hits)
	}
	if !strings.Contains(logs.String(), `"msg":"`+logMessage+`"`) || !strings.Contains(logs.String(), `"tls_name":"other.example"`) {
		t.Fatalf("no %s line in %s", logMessage, logs.String())
	}
}
