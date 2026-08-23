// share-public-gate — authenticating reverse proxy for `share-public`.
//
// Binds the tailnet side of a public slot port and forwards to a local dev
// server only for clients that hold a session cookie. Two ways to earn one,
// both with per-run secrets that no user ever chooses:
//
//	magic link — https://<host><path>?k=<token>. The token is swapped for the
//	             cookie and stripped by an immediate redirect, so the URL a
//	             client is left holding says nothing about how it got in.
//	password   — a three-word phrase on a bare login screen (no username).
//
// A failed attempt of either kind puts the client in a 5s cooldown and is
// printed to the console of the `share-public` run that owns this process.
//
// -nogate-path <prefix> (repeatable) carves out an exception: GET/HEAD under
// that prefix is served straight through with no auth at all. It exists for
// metadata a third party must fetch while holding none of this run's secrets —
// OIDC/OAuth discovery, JWKS, .well-known probes — where the magic-link path's
// 302+cookie would only bounce a tokenless machine client to the login screen.
// Writes are never exempted, and matching is by whole path segment.
//
// Secrets live only in this process's memory: they are generated at startup,
// printed once to the operator's terminal, and die with it. There is no
// persistence and no way to set them by hand — a run that is over cannot be
// re-entered with a password someone wrote down.
//
// This replaces what used to be a plain socat forward. socat is still the
// right mental model for the data path; everything here is the gate in front
// of it. Protocol upgrades (WebSocket, so HMR survives) and streaming
// responses (SSE) pass through, which a hand-rolled forwarder would break.
package main

import (
	"bufio"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/base64"
	"flag"
	"fmt"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

//go:embed words.txt
var wordsFile string

const (
	// __Host- is not decoration: it forbids a Domain attribute and demands
	// Secure + Path=/, so a sibling slot on another hostname cannot set or
	// overwrite this cookie for us.
	cookieName = "__Host-sp"

	// Namespaced far enough out of the way that a real app path is unlikely
	// to collide. Only ever handled for POST.
	loginPath = "/__sp/login"

	tokenParam = "k"

	// A failed attempt locks that client out for this long. Applied before
	// the secret is compared, so a client in cooldown learns nothing from
	// how long the response took.
	failCooldown = 5 * time.Second

	// Backstop against a distributed guess that sidesteps the per-client
	// cooldown. Loose enough that one attacker cannot lock the operator out
	// of their own login screen.
	globalWindow = 5 * time.Second
	globalBurst  = 12

	// Sessions also die with the process; this only bounds a tab left open
	// across a long-running share.
	sessionTTL = 12 * time.Hour

	passwordWords = 3
)

func main() {
	log.SetFlags(log.Ltime)
	log.SetPrefix("share-public: ")

	listen := flag.String("listen", "", "tailnet address:port to serve on")
	target := flag.String("target", "", "local address:port to forward to")
	publicHost := flag.String("public-host", "", "hostname clients reach this by")
	bastion := flag.String("bastion", "", "address allowed to reach -listen (banner only)")
	path := flag.String("path", "/", "path to advertise in the banner")
	var nogate stringList
	flag.Var(&nogate, "nogate-path", "path prefix served without auth, GET/HEAD only; repeatable")
	flag.Parse()

	for name, v := range map[string]string{"listen": *listen, "target": *target, "public-host": *publicHost} {
		if v == "" {
			fmt.Fprintf(os.Stderr, "share-public-gate: -%s is required\n", name)
			os.Exit(64)
		}
	}

	g := &gate{
		password: makePassword(),
		token:    randomString(24),
		nogate:   nogate,
		sessions: map[string]time.Time{},
		limiter:  limiter{last: map[string]time.Time{}},
	}
	g.proxy = newProxy(*target)

	// Listen before printing, so the banner is never a promise the socket
	// has not actually kept.
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		fmt.Fprintf(os.Stderr, "share-public-gate: %v\n", err)
		os.Exit(1)
	}

	base := "https://" + *publicHost + *path
	nogateLine := ""
	if len(g.nogate) > 0 {
		nogateLine = fmt.Sprintf("  no-auth     %s   (GET/HEAD, served without a secret)\n", strings.Join(g.nogate, ", "))
	}
	fmt.Printf(`
share-public: %s  ->  %s
              tailnet %s, open to %s only

  magic link  %s
  password    %s   (login screen on any path)
%s
Paste any localhost URL here for its public form. Ctrl-C to close.

`, base, *target, *listen, *bastion, magicURL(base, g.token), g.password, nogateLine)

	// A share is usually driven from the browser it is serving, so the URL you
	// want to hand out is one you only have half an hour in. Reading stdin lets
	// that URL be pasted back into this terminal and rewritten in place,
	// instead of being reassembled by hand against the banner.
	go rewriteLoop(os.Stdin, *publicHost, g.token, portOf(*target))

	srv := &http.Server{
		Handler:           g,
		ReadHeaderTimeout: 20 * time.Second,
	}
	if err := srv.Serve(ln); err != nil {
		fmt.Fprintf(os.Stderr, "share-public-gate: %v\n", err)
		os.Exit(1)
	}
}

// stringList collects a repeatable string flag in call order.
type stringList []string

func (s *stringList) String() string     { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

type gate struct {
	password string
	token    string
	nogate   []string
	proxy    *httputil.ReverseProxy

	mu       sync.Mutex
	sessions map[string]time.Time

	limiter limiter
}

func (g *gate) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == loginPath {
		if r.Method != http.MethodPost {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		g.handleLogin(w, r)
		return
	}

	// Declared prefixes are served straight through, no auth. Restricted to
	// GET/HEAD so an -nogate-path can never open an unauthenticated write onto
	// the local app — only reads of intentionally-public metadata like
	// /.well-known/*, which a third party fetches carrying no per-run secret.
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		if g.nogated(r.URL.Path) {
			g.proxy.ServeHTTP(w, r)
			return
		}
	}

	if g.authed(r) {
		g.proxy.ServeHTTP(w, r)
		return
	}

	if tok := r.URL.Query().Get(tokenParam); tok != "" {
		g.handleMagic(w, r, tok)
		return
	}

	g.renderLogin(w, r, currentPath(r), "", http.StatusUnauthorized)
}

// handleMagic trades a valid token for a cookie and bounces to the same URL
// without the token. The client never sees a page carrying the token, so it
// cannot leak by Referer, screenshot, or a pasted address bar.
func (g *gate) handleMagic(w http.ResponseWriter, r *http.Request, tok string) {
	ip := clientIP(r)
	if !g.limiter.allow(ip, time.Now()) {
		g.rejectRateLimited(w, r, ip, "magic link")
		return
	}
	if subtle.ConstantTimeCompare([]byte(tok), []byte(g.token)) != 1 {
		g.limiter.fail(ip, time.Now())
		log.Printf("failed magic link from %s for %s", ip, r.URL.Path)
		// Same screen an unauthenticated visitor gets: a wrong token is not
		// worth confirming as "a token, but wrong".
		g.renderLogin(w, r, stripToken(r.URL), "", http.StatusUnauthorized)
		return
	}

	g.setSession(w)
	log.Printf("magic link accepted from %s", ip)
	noStore(w)
	http.Redirect(w, r, stripToken(r.URL), http.StatusSeeOther)
}

func (g *gate) handleLogin(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if err := r.ParseForm(); err != nil {
		g.renderLogin(w, r, "/", "Malformed request.", http.StatusBadRequest)
		return
	}
	next := safeNext(r.PostFormValue("next"))

	if !g.limiter.allow(ip, time.Now()) {
		g.rejectRateLimited(w, r, ip, "password")
		return
	}

	guess := strings.TrimSpace(r.PostFormValue("p"))
	if subtle.ConstantTimeCompare([]byte(guess), []byte(g.password)) != 1 {
		g.limiter.fail(ip, time.Now())
		log.Printf("failed password from %s for %s", ip, next)
		g.renderLogin(w, r, next, "Wrong password. Wait 5 seconds and try again.", http.StatusUnauthorized)
		return
	}

	g.setSession(w)
	log.Printf("password accepted from %s", ip)
	noStore(w)
	http.Redirect(w, r, next, http.StatusSeeOther)
}

func (g *gate) rejectRateLimited(w http.ResponseWriter, r *http.Request, ip, kind string) {
	log.Printf("rate limited %s attempt from %s", kind, ip)
	w.Header().Set("Retry-After", fmt.Sprintf("%d", int(failCooldown.Seconds())))
	g.renderLogin(w, r, currentPath(r), "Too many attempts. Wait 5 seconds.", http.StatusTooManyRequests)
}

// nogated reports whether path falls under a declared no-auth prefix. Matching
// is on path segments, so -nogate-path /.well-known covers /.well-known and
// /.well-known/oidc.json but never /.well-known-evil.
func (g *gate) nogated(path string) bool {
	for _, p := range g.nogate {
		if !strings.HasPrefix(path, p) {
			continue
		}
		rest := path[len(p):]
		if rest == "" || strings.HasSuffix(p, "/") || strings.HasPrefix(rest, "/") {
			return true
		}
	}
	return false
}

func (g *gate) authed(r *http.Request) bool {
	c, err := r.Cookie(cookieName)
	if err != nil || c.Value == "" {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	exp, ok := g.sessions[c.Value]
	if !ok {
		return false
	}
	if time.Now().After(exp) {
		delete(g.sessions, c.Value)
		return false
	}
	return true
}

func (g *gate) setSession(w http.ResponseWriter) {
	sid := randomString(24)
	g.mu.Lock()
	now := time.Now()
	for k, exp := range g.sessions {
		if now.After(exp) {
			delete(g.sessions, k)
		}
	}
	g.sessions[sid] = now.Add(sessionTTL)
	g.mu.Unlock()

	http.SetCookie(w, &http.Cookie{
		Name:     cookieName,
		Value:    sid,
		Path:     "/",
		MaxAge:   int(sessionTTL.Seconds()),
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

// newProxy forwards to the local server, leaving the Host header as the client
// sent it so the app generates links against its public name. Dev servers that
// screen Host (Vite's server.allowedHosts) need the public host allowed.
func newProxy(target string) *httputil.ReverseProxy {
	p := httputil.NewSingleHostReverseProxy(&url.URL{Scheme: "http", Host: target})
	director := p.Director
	p.Director = func(r *http.Request) {
		director(r)
		stripCookie(r, cookieName)
	}
	// -1 flushes each write straight through, which is what SSE and other
	// long-lived streams need to not sit in a buffer.
	p.FlushInterval = -1
	p.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("upstream error: %v", err)
		http.Error(w, "share-public: local server unreachable", http.StatusBadGateway)
	}
	return p
}

// stripCookie keeps the gate's own cookie out of the proxied app's view — it
// has no business seeing it, and an app that echoes cookies cannot leak it.
func stripCookie(r *http.Request, name string) {
	cookies := r.Cookies()
	r.Header.Del("Cookie")
	for _, c := range cookies {
		if c.Name == name {
			continue
		}
		r.AddCookie(c)
	}
}

// limiter holds a per-client cooldown plus a global burst ceiling. Only failed
// attempts feed it: a client that gets the password right first try is never
// made to wait.
type limiter struct {
	mu     sync.Mutex
	last   map[string]time.Time
	recent []time.Time
}

func (l *limiter) allow(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.pruneLocked(now)
	if len(l.recent) >= globalBurst {
		return false
	}
	if t, ok := l.last[ip]; ok && now.Sub(t) < failCooldown {
		return false
	}
	return true
}

func (l *limiter) fail(ip string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.pruneLocked(now)
	l.last[ip] = now
	l.recent = append(l.recent, now)
}

func (l *limiter) pruneLocked(now time.Time) {
	kept := l.recent[:0]
	for _, t := range l.recent {
		if now.Sub(t) < globalWindow {
			kept = append(kept, t)
		}
	}
	l.recent = kept

	for ip, t := range l.last {
		if now.Sub(t) >= failCooldown {
			delete(l.last, ip)
		}
	}
}

// clientIP trusts only the LAST X-Forwarded-For entry. NPM appends the peer it
// actually saw, so anything a client forges lands earlier in the list and is
// ignored — without this, one attacker rotates a header and the cooldown is
// worthless.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		if ip := strings.TrimSpace(parts[len(parts)-1]); ip != "" {
			return ip
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func currentPath(r *http.Request) string {
	u := *r.URL
	u.Scheme, u.Host = "", ""
	return safeNext(u.RequestURI())
}

func stripToken(u *url.URL) string {
	c := *u
	q := c.Query()
	q.Del(tokenParam)
	c.RawQuery = q.Encode()
	c.Scheme, c.Host = "", ""
	return safeNext(c.RequestURI())
}

// safeNext keeps a redirect target on this origin. "//evil.example" is a
// protocol-relative URL, so leading-slash alone is not enough of a check.
func safeNext(next string) string {
	if next == "" || !strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") {
		return "/"
	}
	return next
}

func noStore(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
}

func (g *gate) renderLogin(w http.ResponseWriter, r *http.Request, next, msg string, code int) {
	noStore(w)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	if r.Method == http.MethodHead {
		return
	}
	_ = loginTmpl.Execute(w, struct {
		Next, Msg, Action string
	}{next, msg, loginPath})
}

var loginTmpl = template.Must(template.New("login").Parse(`<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Password required</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; min-height:100vh; display:grid; place-items:center;
         font:16px/1.5 system-ui,sans-serif; background:Canvas; color:CanvasText; }
  form { display:grid; gap:.75rem; width:min(22rem,90vw); }
  input { font:inherit; padding:.6rem .7rem; border:1px solid GrayText; border-radius:.4rem;
          background:Field; color:FieldText; }
  button { font:inherit; padding:.6rem; border:0; border-radius:.4rem;
           background:AccentColor; color:AccentColorText; cursor:pointer; }
  p { margin:0; color:GrayText; }
  .err { color:#c0392b; }
</style>
<form method="post" action="{{.Action}}">
  <p>Enter the password for this share.</p>
  {{if .Msg}}<p class="err">{{.Msg}}</p>{{end}}
  <input type="hidden" name="next" value="{{.Next}}">
  <input type="password" name="p" autofocus autocomplete="off"
         autocapitalize="off" spellcheck="false" placeholder="word-word-word">
  <button type="submit">Enter</button>
</form>
`))

// rewriteLoop turns pasted localhost URLs into their public, token-carrying
// form. Anything unusable is answered with a reason rather than silence — a
// paste that produced no output would be indistinguishable from a wedged
// terminal.
func rewriteLoop(in io.Reader, publicHost, token, wantPort string) {
	sc := bufio.NewScanner(in)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		out, warn, err := rewritePasted(line, publicHost, token, wantPort)
		if err != nil {
			fmt.Printf("  ✗ %v\n\n", err)
			continue
		}
		if warn != "" {
			fmt.Printf("  ! %s\n", warn)
		}
		fmt.Printf("  %s\n\n", out)
	}
}

func rewritePasted(line, publicHost, token, wantPort string) (out, warn string, err error) {
	raw := line
	switch {
	case strings.HasPrefix(raw, "/") && !strings.HasPrefix(raw, "//"):
		// A bare path, as copied out of a devtools network pane.
		raw = "http://localhost" + raw
	case !strings.Contains(raw, "://"):
		// Without this, url.Parse reads "localhost:8080/x" as scheme
		// "localhost" and hands back nothing useful.
		raw = "http://" + strings.TrimPrefix(raw, "//")
	}
	u, perr := url.Parse(raw)
	if perr != nil {
		return "", "", fmt.Errorf("not a URL: %s", line)
	}
	if !isLoopback(u.Hostname()) {
		return "", "", fmt.Errorf("not a localhost URL: %s", u.Hostname())
	}
	if p := u.Port(); p != "" && p != wantPort {
		warn = fmt.Sprintf("pasted port %s, but this share forwards %s", p, wantPort)
	}

	path := u.EscapedPath()
	if path == "" {
		path = "/"
	}
	q := u.Query()
	q.Set(tokenParam, token) // Set, not Add: a re-paste must not stack tokens.
	return "https://" + publicHost + path + "?" + q.Encode(), warn, nil
}

func isLoopback(host string) bool {
	switch host {
	case "localhost", "127.0.0.1", "0.0.0.0", "::1":
		return true
	}
	return false
}

func portOf(hostport string) string {
	_, port, err := net.SplitHostPort(hostport)
	if err != nil {
		return ""
	}
	return port
}

func magicURL(base, token string) string {
	sep := "?"
	if strings.Contains(base, "?") {
		sep = "&"
	}
	return base + sep + tokenParam + "=" + token
}

func makePassword() string {
	words := strings.Fields(wordsFile)
	if len(words) < 16 {
		panic("share-public-gate: wordlist too small")
	}
	out := make([]string, passwordWords)
	for i := range out {
		out[i] = words[randomIndex(len(words))]
	}
	return strings.Join(out, "-")
}

// randomIndex rejects the tail of the random range that would otherwise make
// low indices marginally likelier than high ones.
func randomIndex(n int) int {
	const limit = 1 << 16
	max := limit - (limit % n)
	buf := make([]byte, 2)
	for {
		mustRead(buf)
		if v := int(buf[0])<<8 | int(buf[1]); v < max {
			return v % n
		}
	}
}

func randomString(n int) string {
	buf := make([]byte, n)
	mustRead(buf)
	return base64.RawURLEncoding.EncodeToString(buf)
}

func mustRead(buf []byte) {
	if _, err := rand.Read(buf); err != nil {
		panic("share-public-gate: no entropy: " + err.Error())
	}
}
