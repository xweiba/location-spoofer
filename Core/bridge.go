package main

/*
#cgo CFLAGS: -DGOOS_ios -DNDEBUG
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"net"
	"net/http"
	"runtime/cgo"
	"strconv"
)

//export wloccore_init
func wloccore_init() {}

//export wloccore_hello
func wloccore_hello() {}

//export wloccore_version
func wloccore_version() *C.char {
	return C.CString("0.1.0")
}

//export wloccore_generateca
func wloccore_generateca() (r0, r1 *C.char) {
	logEvent("generateca started")
	cert, key, err := generateCA()
	if err != nil {
		logEvent("generateca failed: " + err.Error())
		return nil, nil
	}
	logEvent("generateca completed")
	return C.CString(string(cert)), C.CString(string(key))
}

//export wloccore_validateca
func wloccore_validateca(certData, keyData *C.char) C.int {
	if certData == nil || keyData == nil {
		return 0
	}
	if _, err := parseCA([]byte(C.GoString(certData)), []byte(C.GoString(keyData))); err != nil {
		logEvent("validateca failed: " + err.Error())
		return 0
	}
	return 1
}

//export wloccore_startproxy
func wloccore_startproxy(certData, keyData *C.char, lat, lon C.double, enabled C.int, accuracy C.int) C.uintptr_t {
	return wloccore_startproxyv2(certData, keyData, lat, lon, enabled, accuracy, 0)
}

//export wloccore_startproxyv2
func wloccore_startproxyv2(certData, keyData *C.char, lat, lon C.double, enabled C.int, accuracy C.int, motionEnabled C.int) C.uintptr_t {
	if certData == nil || keyData == nil {
		return 0
	}
	srv, _, err := startProxy(
		[]byte(C.GoString(certData)),
		[]byte(C.GoString(keyData)),
		float64(lat),
		float64(lon),
		enabled != 0,
		int(accuracy),
		motionEnabled != 0,
	)
	if err != nil {
		logEvent("startproxy failed: " + err.Error())
		return 0
	}
	return C.uintptr_t(cgo.NewHandle(srv))
}

//export wloccore_stopproxy
func wloccore_stopproxy(h C.uintptr_t) C.int {
	logEvent("stopproxy requested")
	srv, handle, ok := proxyForHandle(h)
	if !ok {
		logEvent("stopproxy failed: invalid handle")
		return 1
	}
	handle.Delete()
	if err := stopProxy(srv); err != nil {
		logEvent("stopproxy failed: " + err.Error())
		return 2
	}
	logEvent("stopproxy completed")
	return 0
}

func proxyForHandle(h C.uintptr_t) (server *http.Server, handle cgo.Handle, ok bool) {
	if h == 0 {
		return nil, 0, false
	}
	defer func() {
		if recover() != nil {
			server, handle, ok = nil, 0, false
		}
	}()
	handle = cgo.Handle(h)
	server, ok = handle.Value().(*http.Server)
	return server, handle, ok
}

//export wloccore_setcoords
func wloccore_setcoords(lat, lon C.double, enabled C.int, accuracy C.int) {
	wloccore_setpatchconfig(lat, lon, enabled, accuracy, 0)
}

//export wloccore_setpatchconfig
func wloccore_setpatchconfig(lat, lon C.double, enabled C.int, accuracy C.int, motionEnabled C.int) {
	stateMu.Lock()
	currentLat = float64(lat)
	currentLon = float64(lon)
	currentEnabled = enabled != 0
	currentAccuracy = int(accuracy)
	currentMotionSimulationEnabled = motionEnabled != 0
	stateMu.Unlock()
	logEvent("setpatchconfig enabled=" + strconv.FormatBool(enabled != 0) +
		" accuracy=" + strconv.Itoa(int(accuracy)) +
		" motion=" + strconv.FormatBool(motionEnabled != 0))
}

//export wloccore_getcoords
func wloccore_getcoords() (lat, lon C.double, enabled C.int) {
	stateMu.Lock()
	defer stateMu.Unlock()
	lat = C.double(currentLat)
	lon = C.double(currentLon)
	enabled = 0
	if currentEnabled {
		enabled = 1
	}
	return lat, lon, enabled
}

//export wloccore_drainlogs
func wloccore_drainlogs() *C.char {
	s := drainLogs()
	if s == "" {
		return nil
	}
	return C.CString(s)
}

//export wloccore_startcertserver
func wloccore_startcertserver(certData, keyData *C.char) C.uintptr_t {
	if certData == nil || keyData == nil {
		return 0
	}
	logEvent("start certificate server requested")
	server, err := startCertificateServer([]byte(C.GoString(certData)), []byte(C.GoString(keyData)))
	if err != nil {
		logEvent("start certificate server failed: " + err.Error())
		return 0
	}
	logEvent("certificate server started http=" + server.DownloadURL() + " probe=" + server.ProbeURL())
	return C.uintptr_t(cgo.NewHandle(server))
}

func certificateServerForHandle(h C.uintptr_t) (server *certificateServer, handle cgo.Handle, ok bool) {
	if h == 0 {
		return nil, 0, false
	}
	defer func() {
		if recover() != nil {
			server, handle, ok = nil, 0, false
		}
	}()
	handle = cgo.Handle(h)
	server, ok = handle.Value().(*certificateServer)
	return server, handle, ok
}

//export wloccore_certserver_httpport
func wloccore_certserver_httpport(h C.uintptr_t) C.int {
	server, _, ok := certificateServerForHandle(h)
	if !ok {
		return 0
	}
	return C.int(server.httpLn.Addr().(*net.TCPAddr).Port)
}

//export wloccore_certserver_httpsport
func wloccore_certserver_httpsport(h C.uintptr_t) C.int {
	server, _, ok := certificateServerForHandle(h)
	if !ok {
		return 0
	}
	return C.int(server.httpsLn.Addr().(*net.TCPAddr).Port)
}

//export wloccore_certserver_leafsha256
func wloccore_certserver_leafsha256(h C.uintptr_t) *C.char {
	server, _, ok := certificateServerForHandle(h)
	if !ok {
		return nil
	}
	return C.CString(server.LeafSHA256())
}

//export wloccore_stopcertserver
func wloccore_stopcertserver(h C.uintptr_t) C.int {
	server, handle, ok := certificateServerForHandle(h)
	if !ok {
		return 1
	}
	handle.Delete()
	if err := server.Close(); err != nil {
		return 2
	}
	return 0
}

//export wloccore_testpatch
func wloccore_testpatch(lat, lon C.double, accuracy C.int) *C.char {
	c := wlocCoords{Latitude: float64(lat), Longitude: float64(lon), Accuracy: int(accuracy)}
	original := makeTestWlocBody()
	patched, stats, err := patchWlocBody(original, c)
	if err != nil {
		return C.CString("error: " + err.Error())
	}
	if stats.Locations == 0 {
		return C.CString("error: no location entries found")
	}
	if len(patched) < 10 {
		return C.CString("error: patched body too short")
	}
	newLen := int(binary.BigEndian.Uint16(patched[8:10]))
	if newLen <= 0 || 10+newLen > len(patched) {
		return C.CString("error: invalid patched length")
	}
	newPayload := patched[10 : 10+newLen]
	wantLat := append(writeTag(1, wireVarint), writeVarint(uint64(int64(math.Round(c.Latitude*1e8))))...)
	wantLon := append(writeTag(2, wireVarint), writeVarint(uint64(int64(math.Round(c.Longitude*1e8))))...)
	if !bytes.Contains(newPayload, wantLat) {
		return C.CString("error: patched latitude mismatch")
	}
	if !bytes.Contains(newPayload, wantLon) {
		return C.CString("error: patched longitude mismatch")
	}
	return C.CString(fmt.Sprintf("ok: lat=%f lon=%f wifi=%d cell=%d locations=%d", c.Latitude, c.Longitude, stats.WiFi, stats.Cell, stats.Locations))
}

//export wloccore_testrequesthex
func wloccore_testrequesthex() *C.char {
	return C.CString(fmt.Sprintf("%x", makeTestWlocRequest()))
}

//export wloccore_refreshverifytoken
func wloccore_refreshverifytoken() *C.char {
	return C.CString(refreshVerifyToken())
}

//export wloccore_checkverifytoken
func wloccore_checkverifytoken(token *C.char) C.int {
	if checkVerifyToken(C.GoString(token)) {
		return 1
	}
	return 0
}
