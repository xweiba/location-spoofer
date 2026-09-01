package main

import (
	"bytes"
	"context"
	crand "crypto/rand"
	"crypto/tls"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/elazarl/goproxy"
)

const proxyPort = 8888

var (
	stateMu                        sync.Mutex
	currentLat                     float64
	currentLon                     float64
	currentEnabled                 bool
	currentAccuracy                int
	currentMotionSimulationEnabled bool
	globalCACert                   *tls.Certificate
	verifyToken                    string

	logMu      sync.Mutex
	logEntries []string
)

func logEvent(msg string) {
	line := time.Now().Format("15:04:05.000") + "  " + msg
	logMu.Lock()
	logEntries = append(logEntries, line)
	if len(logEntries) > 200 {
		logEntries = logEntries[len(logEntries)-200:]
	}
	logMu.Unlock()
	log.Printf("%s", msg)
}

func drainLogs() string {
	logMu.Lock()
	defer logMu.Unlock()
	if len(logEntries) == 0 {
		return ""
	}
	out := strings.Join(logEntries, "\n")
	logEntries = nil
	return out
}

func isWlocHost(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if strings.Contains(host, ":") {
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
	}
	switch host {
	case "gs-loc.apple.com", "gs-loc-cn.apple.com",
		"gsp-ssl.ls.apple.com", "bluedot.is.autonavi.com",
		"bluedot.is.autonavi.com.gds.alibabadns.com":
		return true
	}
	return false
}

func newProxy(cert *tls.Certificate) *goproxy.ProxyHttpServer {
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = false

	// Handle non-proxy requests (e.g. Safari browsing directly to 127.0.0.1:8888)
	proxy.NonproxyHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/cert" {
			stateMu.Lock()
			cert := globalCACert
			stateMu.Unlock()
			if cert != nil {
				certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]})
				w.Header().Set("Content-Type", "application/x-x509-ca-cert")
				w.Header().Set("Content-Disposition", "attachment; filename=wloccore-ca.crt")
				w.Write(certPEM)
				return
			}
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte("CA certificate not yet generated"))
			return
		}
		if r.URL.Path == "/" {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Write([]byte(`<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=/cert"><title>CA Certificate</title></head><body><p><a href="/cert">Download CA certificate</a></p></body></html>`))
			return
		}
		if r.URL.Path == "/coords" {
			stateMu.Lock()
			enabled, lat, lon, accuracy, motionEnabled := currentEnabled, currentLat, currentLon, currentAccuracy, currentMotionSimulationEnabled
			stateMu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(fmt.Sprintf(`{"enabled":%t,"lat":%.6f,"lon":%.6f,"accuracy":%d,"motionSimulationEnabled":%t}`, enabled, lat, lon, accuracy, motionEnabled)))
			return
		}
		if r.URL.Path == "/proxy.mobileconfig" || r.URL.Path == "/proxy.mobileconfig/" {
			w.Header().Set("Content-Type", "application/x-apple-aspen-config")
			w.Header().Set("Content-Disposition", "attachment; filename=paopao-proxy.mobileconfig")
			w.Write([]byte(generateProxyMobileConfig()))
			return
		}
		// Serve cert download page for rendoor.cert-like hosts
		if r.Host == "rendoor.cert" || strings.HasPrefix(r.Host, "rendoor.cert:") {
			stateMu.Lock()
			cert := globalCACert
			stateMu.Unlock()
			if cert != nil && r.URL.Path == "/cert" {
				certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]})
				w.Header().Set("Content-Type", "application/x-x509-ca-cert")
				w.Header().Set("Content-Disposition", "attachment; filename=wloccore-ca.crt")
				w.Write(certPEM)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Write([]byte(`<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="2;url=/cert"><title>CA Certificate</title></head><body><p>Downloading CA certificate...</p></body></html>`))
			return
		}
		w.WriteHeader(http.StatusBadGateway)
		w.Write([]byte("This is a proxy server. Use Safari to visit http://127.0.0.1:8888/proxy.mobileconfig for proxy setup, or http://rendoor.cert for CA certificate."))
	})

	if cert != nil {
		mitmAction := &goproxy.ConnectAction{
			Action:    goproxy.ConnectMitm,
			TLSConfig: goproxy.TLSConfigFromCA(cert),
		}
		proxy.OnRequest().HandleConnectFunc(func(host string, ctx *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
			if isWlocHost(host) {
				logEvent("CONNECT " + host + " -> MITM")
				return mitmAction, host
			}
			// MITM baidu.com for WiFi proxy detection
			h := host
			if h2, _, err := net.SplitHostPort(host); err == nil {
				h = h2
			}
			if h == "baidu.com" || h == "www.baidu.com" || strings.HasSuffix(h, ".baidu.com") {
				logEvent("CONNECT " + host + " -> MITM (verify)")
				return mitmAction, host
			}
			// Global Wi-Fi proxy mode sends all HTTPS CONNECT traffic here. Logging
			// unrelated passthrough hosts creates high-volume noise and can disclose
			// browsing destinations; diagnostics only retain WLOC and verify traffic.
			return goproxy.OkConnect, host
		})
	}

	proxy.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		// Do not buffer or log arbitrary global-proxy traffic. Keep requests streaming
		// and do not persist unrelated request content in diagnostics.
		return serveLocalRequests(req, ctx)
	})
	proxy.OnResponse().DoFunc(patchWlocResponse)
	return proxy
}

func serveLocalRequests(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	host := strings.ToLower(req.Host)

	// 代理验证拦截：baidu.com/paopao-verify-* → 返回 token
	h := host
	if h2, _, err := net.SplitHostPort(host); err == nil {
		h = h2
	}
	if (h == "baidu.com" || h == "www.baidu.com") && strings.HasPrefix(req.URL.Path, "/paopao-verify-") {
		token := strings.TrimPrefix(req.URL.Path, "/paopao-verify-")
		logEvent("verify request received")
		if checkVerifyToken(token) {
			resp := goproxy.NewResponse(req, "text/plain", http.StatusOK, token)
			resp.Header.Set("Cache-Control", "no-store")
			return req, resp
		}
	}

	if host != "rendoor.cert" && host != "www.rendoor.cert" {
		return req, nil
	}

	stateMu.Lock()
	cert := globalCACert
	stateMu.Unlock()
	if cert == nil {
		return req, nil
	}

	if req.URL.Path == "/cert" {
		certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]})
		resp := goproxy.NewResponse(req, "application/x-x509-ca-cert", http.StatusOK, string(certPEM))
		resp.Header.Set("Content-Disposition", `attachment; filename=wloccore-ca.crt`)
		return req, resp
	}

	html := `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="2;url=/cert">
<title>Preparing Certificate</title>
</head>
<body>
<p>正在准备 CA 证书，如未弹出请点击 <a href="/cert">这里</a>。</p>
</body>
</html>`
	resp := goproxy.NewResponse(req, "text/html; charset=utf-8", http.StatusOK, html)
	return req, resp
}

func patchWlocResponse(resp *http.Response, ctx *goproxy.ProxyCtx) *http.Response {
	if resp == nil || resp.Request == nil {
		return resp
	}
	if !isWlocHost(resp.Request.Host) || resp.Request.URL.Path != "/clls/wloc" || resp.Request.Method != http.MethodPost {
		return resp
	}

	stateMu.Lock()
	enabled, lat, lon, accuracy, motionEnabled := currentEnabled, currentLat, currentLon, currentAccuracy, currentMotionSimulationEnabled
	stateMu.Unlock()

	const maxPatchBodyBytes int64 = 1 << 20
	if resp.ContentLength > maxPatchBodyBytes {
		logEvent(fmt.Sprintf("wloc response passed through: body exceeds patch limit (%d bytes)", resp.ContentLength))
		return resp
	}

	originalBody := resp.Body
	body, err := io.ReadAll(io.LimitReader(originalBody, maxPatchBodyBytes+1))
	if err != nil {
		logEvent("wloc response read failed: " + err.Error())
		resp.Body = io.NopCloser(io.MultiReader(bytes.NewReader(body), originalBody))
		return resp
	}
	if int64(len(body)) > maxPatchBodyBytes {
		logEvent("wloc response passed through: body exceeds patch limit")
		resp.Body = io.NopCloser(io.MultiReader(bytes.NewReader(body), originalBody))
		return resp
	}
	originalBody.Close()

	if !enabled || resp.StatusCode != http.StatusOK || len(body) == 0 {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		return resp
	}

	patched, stats, err := patchResponseBody(body, wlocCoords{
		Latitude: lat, Longitude: lon, Accuracy: accuracy,
		MotionSimulationEnabled: motionEnabled,
	})
	if err != nil || bytes.Equal(patched, body) {
		if err != nil {
			logEvent("wloc patch skipped: " + err.Error())
		}
		resp.Body = io.NopCloser(bytes.NewReader(body))
		return resp
	}

	resp.Body = io.NopCloser(bytes.NewReader(patched))
	resp.ContentLength = int64(len(patched))
	resp.Header.Del("Content-Encoding")
	resp.Header.Del("Transfer-Encoding")
	resp.Header.Set("Content-Length", strconv.Itoa(len(patched)))
	logEvent(fmt.Sprintf("wloc patched locations=%d wifi=%d cell=%d skipped=%d in=%d out=%d", stats.Locations, stats.WiFi, stats.Cell, stats.Skipped, len(body), len(patched)))
	return resp
}

func generateProxyMobileConfig() string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadDescription</key>
			<string>Configures a global HTTP proxy for location spoofing.</string>
			<key>PayloadDisplayName</key>
			<string>Paopao Location Proxy</string>
			<key>PayloadIdentifier</key>
			<string>com.paopaolabs.location-spoofer.proxy.payload</string>
			<key>PayloadType</key>
			<string>com.apple.proxy.http.global</string>
			<key>PayloadUUID</key>
			<string>` + uuidString() + `</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>GlobalHTTPProxy</key>
			<dict>
				<key>ProxyServer</key>
				<string>127.0.0.1</string>
				<key>ProxyServerPort</key>
				<integer>8888</integer>
				<key>ProxyType</key>
				<string>Manual</string>
			</dict>
		</dict>
	</array>
	<key>PayloadDisplayName</key>
	<string>Paopao Location Proxy</string>
	<key>PayloadIdentifier</key>
	<string>com.paopaolabs.location-spoofer.proxy</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>` + uuidString() + `</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>`
}

func uuidString() string {
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		randomUint32(), randomUint32()&0xFFFF,
		(randomUint32()|0x4000)&0x4FFF,
		(randomUint32()|0x8000)&0xBFFF,
		uint64(randomUint32())<<32|uint64(randomUint32()))
}

func randomUint32() uint32 {
	b := make([]byte, 4)
	crand.Read(b)
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

func startProxy(certPEM, keyPEM []byte, lat, lon float64, enabled bool, accuracy int, motionEnabled bool) (*http.Server, int, error) {
	return startProxyOnPort(certPEM, keyPEM, lat, lon, enabled, accuracy, motionEnabled, proxyPort)
}

func startProxyOnPort(certPEM, keyPEM []byte, lat, lon float64, enabled bool, accuracy int, motionEnabled bool, port int) (*http.Server, int, error) {
	cert, err := parseCA(certPEM, keyPEM)
	if err != nil {
		return nil, 0, err
	}

	stateMu.Lock()
	globalCACert = cert
	currentLat, currentLon, currentEnabled, currentAccuracy = lat, lon, enabled, accuracy
	currentMotionSimulationEnabled = motionEnabled
	stateMu.Unlock()

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return nil, 0, err
	}
	actualPort := listener.Addr().(*net.TCPAddr).Port
	srv := &http.Server{Handler: newProxy(cert)}
	go func() {
		if err := srv.Serve(listener); err != nil && err != http.ErrServerClosed {
			logEvent("proxy server error: " + err.Error())
		}
	}()
	logEvent(fmt.Sprintf("proxy started on 127.0.0.1:%d", actualPort))
	return srv, actualPort, nil
}

func stopProxy(srv *http.Server) error {
	if srv == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := srv.Shutdown(ctx)
	stateMu.Lock()
	globalCACert = nil
	stateMu.Unlock()
	return err
}

func refreshVerifyToken() string {
	token := fmt.Sprintf("%04x", uuidString())
	stateMu.Lock()
	verifyToken = token
	stateMu.Unlock()
	return token
}

func checkVerifyToken(token string) bool {
	stateMu.Lock()
	defer stateMu.Unlock()
	return verifyToken != "" && verifyToken == token
}
