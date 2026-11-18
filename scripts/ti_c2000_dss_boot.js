// =============================================================================
// ti_c2000_dss_boot.js -- the connect / reset / load / run sequence, in ONE place.
//
// This file is injected into the DSS scripts of ti_c2000_service.ps1,
// ti_c2000_run_read.ps1 and ti_c2000_read_continuous.ps1. It exists because that sequence used
// to be copy-pasted three times, and a fix applied to one copy never reached the others:
// on 2026-11-15 the service learned to verify connect() and to stop on Error -1138, while
// both one-shot readers kept the old, broken sequence.
//
// Rules for editing this file:
//   * plain JavaScript only (Rhino): the caller substitutes its bootstrap marker once and
//     everything here runs verbatim in all three callers. Do not spell that marker out in
//     a comment - the "did the placeholder survive?" check greps the generated file for
//     it, and a comment containing it makes a broken injection look fine (and a working
//     one look broken);
//   * every function takes the `log` callback so output goes wherever the caller wants;
//   * return true/false, never throw for an expected failure: the caller writes its own
//     error.txt with its own wording.
// =============================================================================

function dssSleepMs(ms) { java.lang.Thread.sleep(ms); }

// connect() returning normally does NOT prove the link is up: measured 2026-11-15, it
// returned cleanly, then the very next reset() failed with "target is not connected" and
// every load attempt operated on a dead link. isHalted() must reach the target, so use it
// as the proof.
function dssLinkIsUp(session) {
    try {
        // DSS exposes an explicit connection query. A successful connect() return alone
        // is insufficient, and isHalted() by itself only describes debugger state.
        if (!session.target.isConnected(true)) { return false; }
        session.target.isHalted();
        return true;
    } catch (e) { return false; }
}

// Error -1138 (the core refusing to enter debug mode) is the only failure that must not be
// retried: each attempt pushes the probe into -1041 then -150 and can leave debug state it
// cannot remove, so the next session starts worse.
//
// What this must NOT match: "Target reset failed. Error: -1". That is the ordinary,
// recoverable shape of a refused reset - the GEL's real reason (-1138 among them) goes to
// stdout and never reaches the Java exception, so the exception cannot tell them apart.
// An earlier version matched it anyway, which turned every recoverable reset failure into
// a fatal stop: the halt fallback below was skipped and 16 loads that had succeeded earlier
// on 2026-11-15 became zero. Judge -1138 in the parent process, which reads the whole log.
function dssBoardRefusedDebug(msg) {
    var s = "" + msg;
    return (s.indexOf("-1138") >= 0)
        || (s.indexOf("Device refused to allow debug mode") >= 0);
}

// One connect per DSS process. Retrying it five times in the same process made a
// not-yet-openable adapter look like a target fault and could cascade -1041 -> -150.
// The service owns the bounded fresh-process retry and learns Stop-to-connect time.
function dssConnectVerified(session, log) {
    try {
        session.target.connect();
        if (dssLinkIsUp(session)) { log("DSS: connected"); return true; }
        log("DSS: connect returned but the target does not answer");
    } catch (e) {
        var msg = "" + e;
        log("DSS: connect failed: " + msg);
        // Error -1133 "Device blocked debug access because it is currently executing
        // non-debuggable code". TI's own wording offers two ways out: wait for the device
        // to reach debuggable code, or "disable realtime mode, and then attempt to connect".
        // The service sets PoliteRealtimeMode(true) for running-target reads, which is
        // exactly what -1133 refuses. loadti.bat never sets those options, which is why
        // loadti could connect on 2026-11-18 while the service could not (same board,
        // same .ccxml, same minute). Retry once with the realtime options off.
        // The Java exception carries only "emulation failure occurred"; the real code
        // (-1133) goes to DSS stdout, exactly like the -1138/GEL case documented above.
        // So match both shapes, and also retry on any connect failure with realtime off:
        // the retry is cheap and a wrong guess costs one extra connect attempt.
        if (msg.indexOf("-1133") >= 0
            || msg.indexOf("non-debuggable code") >= 0
            || msg.indexOf("emulation failure") >= 0) {
            try { session.target.disconnect(); } catch (eD) { }
            dssSleepMs(500);
            try {
                session.options.setBoolean("PoliteRealtimeMode", false);
                log("DSS: PoliteRealtimeMode off, retrying connect for -1133");
            } catch (eO) { log("DSS: PoliteRealtimeMode not settable here: " + eO); }
            try { session.options.setBoolean("AllowInterruptsWhenHalted", false); } catch (eP) { }
            try {
                session.target.connect();
                if (dssLinkIsUp(session)) {
                    log("DSS: connected (realtime off)");
                    return true;
                }
            } catch (e2) { log("DSS: retry after realtime off failed: " + e2); }
        }
    }
    try { session.target.disconnect(); } catch (eX) { }
    return false;
}

// Reset or fall back sensibly. Returns false only when the link cannot be recovered.
function dssResetVerified(session, log) {
    try { session.target.reset(); log("DSS: reset"); return true; }
    catch (e1) {
        log("DSS: reset failed (" + e1 + ")");
        // A reset exception is NOT a verdict: -6310 (PRSC read), -150 / GEL noise and
        // "Target reset failed. Error: -1" often come from the emulator/GEL layer while
        // the core is still fully reachable, and loadProgram itself halts and loads fine
        // afterwards (measured 2026-11-18). The only question is whether we can still
        // TOUCH the target - dssLinkIsUp() calls isConnected(true) + isHalted(). If yes,
        // continue to load; halt here is best-effort and must not gate the decision.
        if (dssLinkIsUp(session)) {
            try { session.target.halt(); log("DSS: halted (reset noisy, link alive) - continuing to load"); }
            catch (e2) { log("DSS: halt best-effort failed (" + e2 + ") but link answers - continuing to load"); }
            return true;
        }
        log("DSS: link lost after connect, reconnecting");
        try { session.target.disconnect(); } catch (e0) { }
        dssSleepMs(900);
        for (var r = 1; r <= 3; r++) {
            try {
                session.target.connect();
                if (dssLinkIsUp(session)) { session.target.reset(); log("DSS: reset after reconnect (try " + r + ")"); return true; }
            } catch (e3) { log("DSS: reconnect " + r + " failed: " + e3); }
            dssSleepMs(900 * r);
        }
        return false;
    }
}

// 3 attempts, growing wait, and no retry once the core refuses debug mode.
function dssLoadWithRetry(session, outPath, log, attempts) {
    var n = attempts || 3;
    try { session.memory.loadProgram(outPath); log("DSS: loaded"); return true; }
    catch (e1) {
        log("DSS: load failed, attempt 1: " + e1);
        if (dssBoardRefusedDebug(e1)) { log("DSS: board refused debug mode - not retrying"); return false; }
    }
    for (var a = 2; a <= n; a++) {
        try { session.target.halt(); } catch (eh) { }
        try { session.target.reset(); } catch (er) { }
        // Each loadProgram may already have written part of the image before failing.
        // Keep the same minimum gap as between full download rounds.
        dssSleepMs(5000);
        try { session.memory.loadProgram(outPath); log("DSS: loaded on attempt " + a); return true; }
        catch (en) {
            log("DSS: load failed, attempt " + a + ": " + en);
            if (dssBoardRefusedDebug(en)) { log("DSS: board refused debug mode - not retrying"); return false; }
        }
    }
    return false;
}

// runAsynch then prove the core is actually executing, not merely "not halted".
function dssRunVerified(session, log, settleMs) {
    try { session.target.runAsynch(); }
    catch (er) { log("DSS: runAsynch failed: " + er); return false; }
    dssSleepMs(settleMs || 300);
    try {
        if (session.target.isHalted()) { log("DSS: target halted right after run"); return false; }
    } catch (eh) { log("DSS: isHalted failed after run: " + eh); return false; }
    return true;
}

// Halt, wait, disconnect, terminate: the order that keeps the next session loadable.
function dssShutdown(session, log) {
    var ok = true;
    try { if (!session.target.isHalted()) { session.target.halt(); dssSleepMs(150); } }
    catch (eh) { log("DSS: halt before disconnect failed: " + eh); ok = false; }
    try { session.target.disconnect(); log("DSS: disconnected"); }
    catch (ed) { log("DSS: disconnect failed: " + ed); ok = false; }
    try { if (session.target.isConnected(true)) { log("DSS: still connected after disconnect"); ok = false; } }
    catch (ec) { log("DSS: could not verify disconnect: " + ec); ok = false; }
    try { session.terminate(); }
    catch (et) { log("DSS: terminate failed: " + et); ok = false; }
    return ok;
}
