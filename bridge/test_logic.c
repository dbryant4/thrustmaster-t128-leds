// Host-side tests for t128_logic.h. Runs anywhere: cc test_logic.c -o test_logic && ./test_logic
// Pass a telemetry file as argv[1] to also check that it parses (used by fs-mod/tests/run_mock.lua).
#include <stdio.h>
#include "t128_logic.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static int frame_is(const char *plHex, const char *wantHex) {
    unsigned char pl[64], want[64], got[64];
    int pn = 0, wn = 0;
    for (const char *p = plHex; *p; p += 2) { unsigned v; sscanf(p, "%2x", &v); pl[pn++] = (unsigned char)v; }
    for (const char *p = wantHex; *p; p += 2) { unsigned v; sscanf(p, "%2x", &v); want[wn++] = (unsigned char)v; }
    return t128_make_frame(pn ? pl : NULL, pn, got) == wn && !memcmp(got, want, wn);
}

int main(int argc, char **argv) {
    // Frames captured from the Thrustmaster driver
    CHECK(frame_is("", "d0630600e6b8"));
    CHECK(frame_is("5408bf02", "d0630a00fc895408bf02"));
    CHECK(frame_is("21", "d0630700715521"));
    CHECK(frame_is("1f01f465000a71020002257a35e503", "d0631500392e1f01f465000a71020002257a35e503"));

    // Parser: the shape GIANTS' XML writer produces, plus truncated reads
    Telemetry t = {0};
    const char *xml = "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>\n"
        "<telemetry seq=\"42\" active=\"1\" motor=\"1\" rpm=\"1450\" minRpm=\"850\" maxRpm=\"2200\" speed=\"17\" turn=\"2\"/>\n";
    CHECK(telemetry_parse(xml, &t));
    CHECK(t.seq == 42 && t.active == 1 && t.motor == 1 && t.rpm == 1450);
    CHECK(t.minRpm == 850 && t.maxRpm == 2200 && t.speed == 17 && t.turn == TURN_RIGHT);
    Telemetry keep = t;
    CHECK(!telemetry_parse("", &t));
    CHECK(!telemetry_parse("<telemetry seq=\"43\" active=\"1\" motor=\"1\" rpm=\"14", &t));
    CHECK(!telemetry_parse("<telemetry seq=\"43\" active=\"1\" motor=\"1\" rpm=\"1450\" minRpm=\"850\"", &t));
    CHECK(!memcmp(&keep, &t, sizeof(t)));   // failed parses leave the last good value alone

    // Heartbeat for the mod
    char beat[160];
    bridge_beat_format(beat, sizeof(beat), 7, 5);
    CHECK(!strcmp(beat, "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>\n<bridge version=\"1\" beat=\"7\" wheel=\"1\"/>\n"));
    bridge_beat_format(beat, sizeof(beat), 8, 0);
    CHECK(strstr(beat, "beat=\"8\" wheel=\"0\"") != NULL);

    // RPM bar: 55/68/80/92% and flash at 95%
    CHECK(rpm_leds(0.40, 0, 1) == 0);
    CHECK(rpm_leds(0.55, 0, 1) == 1);
    CHECK(rpm_leds(0.68, 0, 1) == 2);
    CHECK(rpm_leds(0.80, 0, 1) == 3);
    CHECK(rpm_leds(0.92, 0, 1) == 4);
    CHECK(rpm_leds(0.95, 0, 1) == 5);
    CHECK(rpm_leds(1.10, 0, 0) == 4);       // --no-flash
    // Hysteresis: holds a level just under its threshold, lets go 1.5% lower
    CHECK(rpm_leds(0.675, 2, 1) == 2);
    CHECK(rpm_leds(0.660, 2, 1) == 1);
    CHECK(rpm_leds(0.675, 1, 1) == 1);
    CHECK(rpm_leds(0.30, 5, 1) == 0);

    // Signals, 130 ms steps
    int right[] = {1, 2, 3, 4, 0, 0, 1}, left[] = {4, 3, 2, 1, 0, 0, 4};
    for (int i = 0; i < 7; i++) {
        CHECK(signal_leds(TURN_RIGHT, i * 130 + 5) == right[i]);
        CHECK(signal_leds(TURN_LEFT, i * 130 + 5) == left[i]);
    }
    CHECK(signal_leds(TURN_HAZARD, 0) == 4 && signal_leds(TURN_HAZARD, 380) == 0 && signal_leds(TURN_HAZARD, 760) == 4);

    // Whole pipeline
    LedState s = {0};
    LedOptions opt = {1, 1}, noBlink = {1, 0};
    Telemetry d = {1, 1, 1, 1900, 850, 2200, 12, TURN_OFF};   // 86% -> 3 LEDs
    CHECK(led_update(&s, &d, 1000, opt) == 3);
    d.turn = TURN_LEFT;                                        // signal overrides RPM, restarts its phase
    CHECK(led_update(&s, &d, 5000, opt) == 4);
    CHECK(led_update(&s, &d, 5135, opt) == 3);
    d.turn = TURN_OFF;
    CHECK(led_update(&s, &d, 6000, opt) == 3);
    d.motor = 0; d.turn = TURN_HAZARD;                         // hazards work with the engine off
    CHECK(led_update(&s, &d, 7000, opt) == 4);
    d.turn = TURN_OFF;
    CHECK(led_update(&s, &d, 8000, opt) == 0);
    d.motor = 1; d.active = 0;                                 // on foot / game gone
    CHECK(led_update(&s, &d, 9000, opt) == 0);
    d.active = 1; d.maxRpm = 0;                                // never divide by a zero max
    CHECK(led_update(&s, &d, 9100, opt) == 0);

    // Idle blink: engine running below the first step blinks LED 1, 1 s on / 1 s off
    LedState b = {0};
    Telemetry idle = {1, 1, 1, 850, 850, 2200, 0, TURN_OFF};   // 39%
    CHECK(led_update(&b, &idle, 50000, opt) == 1);             // lit as soon as the engine runs
    CHECK(led_update(&b, &idle, 50999, opt) == 1);
    CHECK(led_update(&b, &idle, 51000, opt) == 0);
    CHECK(led_update(&b, &idle, 51999, opt) == 0);
    CHECK(led_update(&b, &idle, 52000, opt) == 1);
    idle.rpm = 1300;                                           // 59%: the bar takes over, steady
    CHECK(led_update(&b, &idle, 52500, opt) == 1);
    CHECK(led_update(&b, &idle, 53100, opt) == 1);
    CHECK(led_update(&b, &idle, 54100, opt) == 1);
    idle.rpm = 850;                                            // back to idle: the blink starts over, lit
    CHECK(led_update(&b, &idle, 54500, opt) == 1);
    CHECK(led_update(&b, &idle, 55500, opt) == 0);
    idle.turn = TURN_HAZARD;                                   // signals still override
    CHECK(led_update(&b, &idle, 56000, opt) == 4);
    idle.turn = TURN_OFF; idle.motor = 0;                      // engine off: dark
    CHECK(led_update(&b, &idle, 57000, opt) == 0);
    CHECK(led_update(&b, &idle, 58000, opt) == 0);
    idle.motor = 1;                                            // --no-idle-blink: dark below the first step
    CHECK(led_update(&b, &idle, 59000, noBlink) == 0);
    CHECK(led_update(&b, &idle, 60000, noBlink) == 0);

    // Fake source stays in range for a whole cycle
    for (unsigned ms = 0; ms < 40000; ms += 50) {
        telemetry_fake(ms, &t);
        CHECK(t.rpm >= 800 && t.rpm <= 2200 && t.turn >= TURN_OFF && t.turn <= TURN_HAZARD);
        int lit = led_update(&s, &t, ms, opt);
        CHECK(lit >= 0 && lit <= 5);
    }

    if (argc > 1) {
        char buf[1024] = {0};
        FILE *f = fopen(argv[1], "rb");
        CHECK(f != NULL);
        if (f) { size_t n = fread(buf, 1, sizeof(buf) - 1, f); buf[n] = 0; fclose(f); }
        CHECK(telemetry_parse(buf, &t));
        printf("%s: seq %d active %d motor %d rpm %d/%d-%d speed %d turn %d\n", argv[1],
               t.seq, t.active, t.motor, t.rpm, t.minRpm, t.maxRpm, t.speed, t.turn);
    }

    printf(fails ? "%d check(s) FAILED\n" : "all checks passed\n", fails);
    return fails != 0;
}
