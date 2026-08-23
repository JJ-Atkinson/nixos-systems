package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestNogated(t *testing.T) {
	g := &gate{nogate: []string{"/.well-known", "/pub/"}}

	cases := []struct {
		path string
		want bool
	}{
		{"/.well-known", true},              // exact prefix, no trailing slash
		{"/.well-known/", true},             // segment boundary
		{"/.well-known/oidc.json", true},    // nested
		{"/.well-known-evil", false},        // must not match a longer segment
		{"/.well-known-evil/x", false},      // ...even when nested
		{"/pub/", true},                     // prefix ends in slash: exact
		{"/pub/a/b", true},                  // nested under slash prefix
		{"/pub", false},                     // slash prefix does not match the bare form
		{"/private", false},                 // unrelated
		{"/", false},                        // root is never nogated unless declared
	}
	for _, c := range cases {
		if got := g.nogated(c.path); got != c.want {
			t.Errorf("nogated(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

// newTestGate wires a gate in front of a backend that echoes a marker, so a
// request that reaches the upstream is distinguishable from one the gate
// answered itself (login screen).
func newTestGate(t *testing.T, nogate ...string) (*gate, *httptest.Server) {
	t.Helper()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Reached-Backend", "1")
		_, _ = w.Write([]byte("upstream:" + r.Method + " " + r.URL.Path))
	}))
	t.Cleanup(backend.Close)

	g := &gate{
		password: "correct-horse-battery",
		token:    "tok123",
		nogate:   nogate,
		sessions: map[string]time.Time{},
		limiter:  limiter{last: map[string]time.Time{}},
	}
	g.proxy = newProxy(strings.TrimPrefix(backend.URL, "http://"))
	return g, backend
}

func TestNogatePassthrough_GETReachesUpstreamUnauthed(t *testing.T) {
	g, _ := newTestGate(t, "/.well-known")

	req := httptest.NewRequest(http.MethodGet, "/.well-known/oidc.json", nil)
	rec := httptest.NewRecorder()
	g.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if rec.Header().Get("X-Reached-Backend") != "1" {
		t.Fatalf("did not reach upstream; body = %q", rec.Body.String())
	}
	if ck := rec.Header().Get("Set-Cookie"); ck != "" {
		t.Errorf("nogate response set a cookie: %q", ck)
	}
}

func TestNogatePassthrough_HEADAllowed(t *testing.T) {
	g, _ := newTestGate(t, "/.well-known")

	req := httptest.NewRequest(http.MethodHead, "/.well-known/oidc.json", nil)
	rec := httptest.NewRecorder()
	g.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("HEAD status = %d, want 200", rec.Code)
	}
}

func TestNogatePassthrough_WriteMethodsStillGated(t *testing.T) {
	g, _ := newTestGate(t, "/.well-known")

	for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		req := httptest.NewRequest(m, "/.well-known/oidc.json", nil)
		rec := httptest.NewRecorder()
		g.ServeHTTP(rec, req)

		if rec.Header().Get("X-Reached-Backend") == "1" {
			t.Errorf("%s under nogate reached upstream — writes must stay gated", m)
		}
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s status = %d, want 401 (login screen)", m, rec.Code)
		}
	}
}

func TestNonNogatePathStillRequiresAuth(t *testing.T) {
	g, _ := newTestGate(t, "/.well-known")

	req := httptest.NewRequest(http.MethodGet, "/private", nil)
	rec := httptest.NewRecorder()
	g.ServeHTTP(rec, req)

	if rec.Header().Get("X-Reached-Backend") == "1" {
		t.Fatalf("unauthed GET outside nogate reached upstream")
	}
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

func TestNoNogatePathsConfigured_EverythingGated(t *testing.T) {
	g, _ := newTestGate(t) // no nogate prefixes

	req := httptest.NewRequest(http.MethodGet, "/.well-known/oidc.json", nil)
	rec := httptest.NewRecorder()
	g.ServeHTTP(rec, req)

	if rec.Header().Get("X-Reached-Backend") == "1" {
		t.Fatalf("with no -nogate-path, /.well-known must still be gated")
	}
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

// A magic-link (token) request to an ordinary path must still 302 + cookie, so
// the passthrough change did not disturb the browser auth path.
func TestMagicLinkStillRedirects(t *testing.T) {
	g, _ := newTestGate(t, "/.well-known")

	u := &url.URL{Path: "/app", RawQuery: "k=tok123"}
	req := httptest.NewRequest(http.MethodGet, u.String(), nil)
	rec := httptest.NewRecorder()
	g.ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("magic link status = %d, want 303", rec.Code)
	}
	if !strings.Contains(rec.Header().Get("Set-Cookie"), cookieName) {
		t.Errorf("magic link did not set session cookie")
	}
	if loc := rec.Header().Get("Location"); strings.Contains(loc, "k=tok123") {
		t.Errorf("redirect still carries token: %q", loc)
	}
}
