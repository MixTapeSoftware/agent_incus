// egress/boxen-smokescreen/main.go
// bxn's smokescreen: upstream's main.go, unchanged smokescreen underneath,
// plus one check on CONNECT tunnels through the documented ProxyDialTimeout
// hook. build-smokescreen.sh builds it inside smokescreen's own tree, so it
// imports only the standard library and what smokescreen vendors.
//
// The check: smokescreen allows a tunnel by the host in the CONNECT line, and
// a client could then use that tunnel for a different name served from the
// same front end. So the first bytes the client sends must be a TLS
// ClientHello whose server name is the host it asked for. Nothing is
// decrypted; the ClientHello is plain text.
//
// BOXEN_TLS_NAME_CHECK, set by boxen-proxy-run, chooses what happens:
// enforce (the default) closes such a tunnel, report logs it and lets it
// through, off skips the check.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/stripe/goproxy"
	"github.com/stripe/smokescreen/cmd"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	"github.com/stripe/smokescreen/pkg/smokescreen/hostport"
)

// The one log line each refused tunnel writes; boxen-egress-ctl looks for it.
const logMessage = "BOXEN-TLS-NAME-CHECK"

// TLS allows a record body of at most 16 KB (RFC 8446, 5.1), so no more is
// held back than that and its 5-byte header.
const maxRecord = 16384

// As upstream: the role is the client certificate's name. bxn uses none, so
// allow_missing_role applies.
func defaultRoleFromRequest(req *http.Request) (string, error) {
	if req.TLS == nil {
		return "", smokescreen.MissingRoleError("defaultRoleFromRequest requires TLS")
	}
	if len(req.TLS.PeerCertificates) == 0 {
		return "", smokescreen.MissingRoleError("client did not provide certificate")
	}
	return req.TLS.PeerCertificates[0].Subject.CommonName, nil
}

func main() {
	mode := os.Getenv("BOXEN_TLS_NAME_CHECK")
	if mode == "" {
		mode = "enforce"
	}
	if mode != "enforce" && mode != "report" && mode != "off" {
		logrus.Fatalf("BOXEN_TLS_NAME_CHECK must be enforce, report or off, not %q", mode)
	}
	conf, err := cmd.NewConfiguration(nil, nil)
	if err != nil {
		logrus.Fatalf("Could not create configuration: %v", err)
	}
	if conf == nil {
		return // --help or --version, handled by NewConfiguration
	}
	conf.RoleFromRequest = defaultRoleFromRequest
	conf.Log.Formatter = &logrus.JSONFormatter{}
	log.SetOutput(&smokescreen.Log2LogrusWriter{Entry: conf.Log.WithField("stdlog", "1")})
	log.SetFlags(0)
	if mode != "off" {
		conf.ProxyDialTimeout = nameCheckDialer(mode == "enforce", conf.Log)
	}
	smokescreen.StartWithConfig(conf, nil)
}

// nameCheckDialer dials as smokescreen does without the hook, and wraps the
// connection of each CONNECT tunnel in a checkedConn. Plain HTTP requests go
// through smokescreen whole, so it already sees their host; they're untouched.
func nameCheckDialer(enforce bool, logger *logrus.Logger) func(context.Context, string, string, time.Duration) (net.Conn, error) {
	return func(ctx context.Context, network, address string, timeout time.Duration) (net.Conn, error) {
		pctx, _ := ctx.Value(goproxy.ProxyContextKey).(*goproxy.ProxyCtx)
		conn, err := net.DialTimeout(network, address, timeout)
		if err != nil || pctx == nil || pctx.Req == nil || pctx.Req.Method != http.MethodConnect {
			return conn, err
		}
		// The host as smokescreen normalized it for its allowlist.
		dest, err := hostport.New(pctx.Req.Host, false)
		if err != nil {
			conn.Close()
			return nil, err
		}
		return &checkedConn{Conn: conn, host: dest.Host, port: dest.Port, enforce: enforce, log: logger}, nil
	}
}

// checkedConn holds back what the client writes until it has the whole
// first TLS record, then forwards it only if the record's ClientHello names
// the tunnel's host. goproxy writes from one goroutine, so no lock is needed.
type checkedConn struct {
	net.Conn
	host    string
	port    int
	enforce bool
	log     *logrus.Logger
	held    []byte
	done    bool
	err     error
}

func (c *checkedConn) Write(b []byte) (int, error) {
	if c.done {
		if c.err != nil {
			return 0, c.err
		}
		return c.Conn.Write(b)
	}
	c.held = append(c.held, b...)
	name, reason, ok := checkHello(c.held, c.host)
	if !ok {
		return len(b), nil // not the whole record yet
	}
	c.done = true
	held := c.held
	c.held = nil
	if reason != "" {
		c.report(name, reason)
		if c.enforce {
			// An error from Write ends goproxy's copy, which closes the
			// tunnel. Nothing held back was sent.
			c.err = errors.New("boxen: tunnel closed by the TLS name check (" + reason + ")")
			return 0, c.err
		}
	}
	if _, err := c.Conn.Write(held); err != nil {
		return 0, err
	}
	return len(b), nil
}

// checkHello reads the first TLS record in b. ok is false while more bytes
// are needed. reason is empty when the ClientHello names host, and otherwise
// says why the tunnel is refused.
func checkHello(b []byte, host string) (name, reason string, ok bool) {
	// Every TLS connection starts with a handshake record (type 22). Anything
	// else is another protocol, where the proxy can't see a name at all.
	if len(b) > 0 && b[0] != 22 {
		return "", "not_tls", true
	}
	if len(b) < 5 {
		return "", "", false
	}
	// A record longer than TLS allows isn't TLS; refusing it also caps what
	// is held back.
	n := int(b[3])<<8 | int(b[4])
	if n > maxRecord {
		return "", "malformed", true
	}
	if len(b) < 5+n {
		return "", "", false
	}
	name, err := helloName(b[:5+n])
	switch {
	case err != nil:
		// Not a ClientHello crypto/tls accepts, so a server might read
		// a name out of it that this check didn't.
		return "", "malformed", true
	case name == "":
		// No name: a shared front end would pick a site some other way.
		return "", "no_name", true
	case !sameHost(name, host):
		// The tunnel was allowed for host and is being used for name.
		return name, "mismatch", true
	}
	return name, "", true
}

// helloName has crypto/tls parse the ClientHello in rec, so this file holds
// no TLS parser of its own. The handshake stops as soon as the server name
// is known; nothing is ever sent to the client.
func helloName(rec []byte) (string, error) {
	var name string
	stop := errors.New("stop")
	srv := tls.Server(&replayConn{r: bytes.NewReader(rec)}, &tls.Config{
		GetConfigForClient: func(h *tls.ClientHelloInfo) (*tls.Config, error) {
			name = h.ServerName
			return nil, stop
		},
	})
	if err := srv.Handshake(); !errors.Is(err, stop) {
		return "", errors.New("no ClientHello")
	}
	return name, nil
}

// sameHost compares hostnames as DNS does: ASCII letters in either case,
// and one trailing dot ignored. strings.EqualFold isn't used because it
// also folds non-ASCII letters, such as the Kelvin sign into k.
func sameHost(a, b string) bool {
	a, b = strings.TrimSuffix(a, "."), strings.TrimSuffix(b, ".")
	if a == "" || len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		x, y := a[i], b[i]
		if 'A' <= x && x <= 'Z' {
			x += 'a' - 'A'
		}
		if 'A' <= y && y <= 'Z' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

// report writes the one log line for a refused tunnel: the names and the
// reason, never bytes of the stream. The names come from the client, so they
// are cut short and anything but printable ASCII is replaced.
func (c *checkedConn) report(name, reason string) {
	c.log.WithFields(logrus.Fields{
		"connect_host": printable(c.host),
		"connect_port": c.port,
		"tls_name":     printable(name),
		"reason":       reason,
		"enforced":     c.enforce,
	}).Warn(logMessage)
}

func printable(s string) string {
	if len(s) > 253 {
		s = s[:253]
	}
	return strings.Map(func(r rune) rune {
		if r < 0x21 || r > 0x7e {
			return '?'
		}
		return r
	}, s)
}

// replayConn gives crypto/tls the held-back bytes to read and discards what
// it writes (the alert it sends when the handshake stops).
type replayConn struct{ r *bytes.Reader }

func (c *replayConn) Read(b []byte) (int, error)       { return c.r.Read(b) }
func (c *replayConn) Write(b []byte) (int, error)      { return len(b), nil }
func (c *replayConn) Close() error                     { return nil }
func (c *replayConn) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (c *replayConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (c *replayConn) SetDeadline(time.Time) error      { return nil }
func (c *replayConn) SetReadDeadline(time.Time) error  { return nil }
func (c *replayConn) SetWriteDeadline(time.Time) error { return nil }
