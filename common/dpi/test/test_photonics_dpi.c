/* ---------------------------------------------------------------------------
 * test_photonics_dpi.c : standalone unit tests for the photonics DPI-C model.
 *
 *   NO SIMULATOR IS INVOLVED. That is the entire point: the optical physics is
 *   ordinary C, so it can be regression-tested in a second on any machine with
 *   gcc, in CI, and by anyone who does not hold an EDA licence. The simulator
 *   only ever needs to prove the LINKAGE works; the maths is proven here.
 *
 *   Build + run:  make test
 *
 *   `sv_ring_event` is normally an export from SystemVerilog. Here it is a stub
 *   that records what the model reported, which is also how the event tests
 *   observe the callbacks.
 *
 *   Several checks compare doubles with ==, deliberately. The C model must be
 *   BIT-identical to ring_model.sv, so the values it produces at the tabulated
 *   operating points (trans = 1.0 exactly on resonance, 0.5 exactly at the
 *   half-linewidth, temp = dac/tau exactly after one step) are exact in IEEE
 *   754 and a tolerance would hide a real port error.
 * ------------------------------------------------------------------------- */
#include "photonics_dpi.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

/* --- tiny test harness -------------------------------------------------- */

static const char *g_sec = "(none)";
static int g_sec_checks;
static int g_sec_fails;
static int g_tot_checks;
static int g_tot_fails;
static int g_sections;
static int g_sections_failed;

#if defined(__GNUC__)
__attribute__((format(printf, 3, 4)))
#endif
static void report(int ok, int line, const char *fmt, ...)
{
    g_sec_checks++;
    if (!ok) {
        va_list ap;
        g_sec_fails++;
        printf("   [FAIL] line %d: ", line);
        va_start(ap, fmt);
        vprintf(fmt, ap);
        va_end(ap);
        printf("\n");
    }
}

#define CHECK(cond, ...) report((cond) ? 1 : 0, __LINE__, __VA_ARGS__)

static void begin(const char *name)
{
    g_sec        = name;
    g_sec_checks = 0;
    g_sec_fails  = 0;
}

static void end(void)
{
    g_tot_checks += g_sec_checks;
    g_tot_fails  += g_sec_fails;
    g_sections++;
    if (g_sec_fails != 0) {
        g_sections_failed++;
        printf("[FAIL] %-38s %2d checks, %d failed\n",
               g_sec, g_sec_checks, g_sec_fails);
    } else {
        printf("[PASS] %-38s %2d checks\n", g_sec, g_sec_checks);
    }
}

static int close_to(double a, double b, double tol)
{
    return fabs(a - b) <= tol;
}

/* --- sv_ring_event stub (stands in for the SystemVerilog export) -------- */

static int    g_ev_cross;
static int    g_ev_clip;
static int    g_ev_other;
static double g_ev_last_cross;
static double g_ev_last_clip;

void sv_ring_event(int ev, double value)
{
    switch (ev) {
    case PHOTONICS_EV_RESONANCE_CROSS:
        g_ev_cross++;
        g_ev_last_cross = value;
        break;
    case PHOTONICS_EV_ADC_CLIP:
        g_ev_clip++;
        g_ev_last_clip = value;
        break;
    default:
        g_ev_other++;
        break;
    }
}

static void ev_clear(void)
{
    g_ev_cross      = 0;
    g_ev_clip       = 0;
    g_ev_other      = 0;
    g_ev_last_cross = 0.0;
    g_ev_last_clip  = 0.0;
}

/* Drive one code for n clocks, return the last ADC sample. */
static int run_n(void *h, int dac, int n, double *d_out, double *t_out)
{
    int adc = 0;
    int i;
    for (i = 0; i < n; i++) {
        adc = photonics_ring_step(h, dac, 0.0, d_out, t_out);
    }
    return adc;
}

/* --- 1. ABI hygiene: version, handles, NULL safety ---------------------- */

static void test_abi_hygiene(void)
{
    const char *v;
    void       *h;
    double      d = 12345.0;
    double      t = 12345.0;
    int         adc;

    begin("abi: version / handles / NULL");
    ev_clear();

    v = photonics_dpi_version();
    CHECK(v != NULL, "version() returned NULL");
    CHECK(v != NULL && v[0] != '\0', "version() returned an empty string");

    h = photonics_ring_new();
    CHECK(h != NULL, "new() returned NULL");
    photonics_ring_free(h);
    photonics_ring_free(NULL); /* must be a no-op, like free() */

    /* Every entry point must tolerate a null chandle. */
    photonics_ring_config(NULL, 1.0, 1.0, 1.0, 1.0, 1.0, 1, 4095);
    photonics_ring_reset(NULL);
    adc = photonics_ring_step(NULL, 100, 0.0, &d, &t);
    CHECK(adc == 0, "step(NULL) returned %d, expected 0", adc);
    CHECK(d == 0.0 && t == 0.0, "step(NULL) left outputs at %g / %g", d, t);
    CHECK(g_ev_cross + g_ev_clip + g_ev_other == 0,
          "a NULL handle emitted %d events",
          g_ev_cross + g_ev_clip + g_ev_other);

    /* Null output pointers are legal too. */
    h = photonics_ring_new();
    photonics_ring_config(h, 0.0, 512.0, 1.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    adc = photonics_ring_step(h, 0, 0.0, NULL, NULL);
    CHECK(adc == 3000, "step() with NULL out-pointers returned %d, expected 3000",
          adc);
    photonics_ring_free(h);

    end();
}

/* --- 2. Lorentzian lineshape (spec 7.2) -------------------------------- */

static void test_lorentzian(void)
{
    void  *h;
    double d = 0.0;
    double t = 0.0;
    int    adc;

    begin("lorentzian: 1.0 on res, 0.5 at fwhm/2");
    ev_clear();

    /* tau = 1 makes the thermal lag a pass-through (temp == dac exactly after
     * one step), which isolates the optical maths from the lag. */
    h = photonics_ring_new();
    photonics_ring_config(h, 1000.0, 512.0, 1.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);

    adc = photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(t == 1000.0, "temp after one tau=1 step is %.17g, expected 1000", t);
    CHECK(d == 0.0, "detune on resonance is %.17g, expected 0", d);
    CHECK(adc == 3000, "trans(0) gave adc %d, expected p_peak 3000", adc);

    adc = photonics_ring_step(h, 1256, 0.0, &d, &t); /* d = +fwhm/2 */
    CHECK(d == 256.0, "detune is %.17g, expected +256", d);
    CHECK(adc == 1500, "trans(+fwhm/2) gave adc %d, expected 1500", adc);

    adc = photonics_ring_step(h, 744, 0.0, &d, &t); /* d = -fwhm/2 */
    CHECK(d == -256.0, "detune is %.17g, expected -256", d);
    CHECK(adc == 1500, "trans(-fwhm/2) gave adc %d, expected 1500 (symmetric)",
          adc);
    photonics_ring_free(h);

    /* Same three points at high resolution, so the 0.5 is checked to 7 digits
     * rather than to 12-bit ADC granularity. */
    h = photonics_ring_new();
    photonics_ring_config(h, 100.0, 100.0, 1.0, 2000000.0, 0.0, 1, 1000000000);
    photonics_ring_reset(h);

    adc = photonics_ring_step(h, 100, 0.0, &d, &t);
    CHECK(adc == 2000000, "hi-res trans(0) gave %d, expected 2000000", adc);
    adc = photonics_ring_step(h, 150, 0.0, &d, &t);
    CHECK(adc == 1000000, "hi-res trans(fwhm/2) gave %d, expected 1000000 (0.5)",
          adc);
    adc = photonics_ring_step(h, 50, 0.0, &d, &t);
    CHECK(adc == 1000000, "hi-res trans(-fwhm/2) gave %d, expected 1000000", adc);
    adc = photonics_ring_step(h, 200, 0.0, &d, &t); /* |d| = fwhm -> 1/5 */
    CHECK(adc == 400000, "hi-res trans(fwhm) gave %d, expected 400000 (0.2)", adc);

    /* A narrower ring must be sharper at the same detuning: monotone in fwhm. */
    photonics_ring_config(h, 100.0, 50.0, 1.0, 2000000.0, 0.0, 1, 1000000000);
    adc = photonics_ring_step(h, 150, 0.0, &d, &t);
    CHECK(adc < 1000000, "halving fwhm did not sharpen the line (adc %d)", adc);
    photonics_ring_free(h);

    CHECK(g_ev_clip == 0, "unexpected %d clip events during lineshape test",
          g_ev_clip);
    end();
}

/* --- 3. thermal lag: converges, and at the right rate ------------------ */

static void test_thermal_lag(void)
{
    void  *h;
    double d = 0.0;
    double t = 0.0;
    double expect;
    double tau = 8.0;
    double drive = 1000.0;
    int    n;
    int    bad_rate = 0;

    begin("thermal lag: converges at 1/tau rate");
    ev_clear();

    h = photonics_ring_new();
    photonics_ring_config(h, 0.0, 512.0, tau, 0.0, 0.0, 1, 4095);
    photonics_ring_reset(h);

    /* First step from cold is exactly drive/tau -- exact in IEEE 754. */
    (void)photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(t == 125.0, "first step with tau=8 gave temp %.17g, expected 125", t);

    /* Closed form of temp <- temp + (D - temp)/tau from temp = 0:
     *     temp(n) = D * (1 - (1 - 1/tau)^n)                                 */
    for (n = 2; n <= 40; n++) {
        (void)photonics_ring_step(h, 1000, 0.0, &d, &t);
        expect = drive * (1.0 - pow(1.0 - 1.0 / tau, (double)n));
        if (!close_to(t, expect, 1e-9)) {
            bad_rate++;
            if (bad_rate == 1) {
                printf("   [note] n=%d temp=%.17g expected=%.17g\n", n, t, expect);
            }
        }
    }
    CHECK(bad_rate == 0, "%d of 39 lag samples deviated from D*(1-(1-1/tau)^n)",
          bad_rate);

    /* Converges to the drive, and detune converges with it. */
    (void)run_n(h, 1000, 400, &d, &t);
    CHECK(close_to(t, 1000.0, 1e-9), "temp did not converge: %.17g", t);
    CHECK(close_to(d, 1000.0, 1e-9), "detune did not track temp: %.17g", d);

    /* Decays toward a lower drive at the same rate. */
    (void)photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(close_to(t, 875.0, 1e-9),
          "first decay step gave %.17g, expected 875 (1000 - 1000/8)", t);
    (void)run_n(h, 0, 400, &d, &t);
    CHECK(close_to(t, 0.0, 1e-9), "temp did not decay back to 0: %.17g", t);

    /* A different tau must give a different (faster) rate. */
    photonics_ring_config(h, 0.0, 512.0, 2.0, 0.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    (void)photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(t == 500.0, "first step with tau=2 gave temp %.17g, expected 500", t);

    photonics_ring_free(h);
    end();
}

/* --- 4. ADC quantiser: clamp at 0 and at adc_max ----------------------- */

static void test_adc_clamp(void)
{
    void  *h;
    double d = 0.0;
    double t = 0.0;
    int    adc;

    begin("adc: clamps at 0 and adc_max");

    h = photonics_ring_new();

    /* Hard over-range: clamps AND reports a clip. */
    ev_clear();
    photonics_ring_config(h, 0.0, 512.0, 1.0, 1000000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(adc == 4095, "over-range sample gave %d, expected the 4095 rail", adc);
    CHECK(g_ev_clip == 1, "over-range raised %d clip events, expected 1",
          g_ev_clip);
    CHECK(close_to(g_ev_last_clip, 1000000.0, 1e-6),
          "clip event reported %g, expected the unquantized 1e6", g_ev_last_clip);

    /* Exactly at the top code: legal, NOT a clip (the clamp never engaged). */
    ev_clear();
    photonics_ring_config(h, 0.0, 512.0, 1.0, 4095.0, 0.0, 1, 4095);
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(adc == 4095, "adc_r == adc_max gave %d, expected 4095", adc);
    CHECK(g_ev_clip == 0, "adc_r == adc_max raised a clip event (%d)", g_ev_clip);

    /* Half an LSB above: now the clamp really engages. */
    ev_clear();
    photonics_ring_config(h, 0.0, 512.0, 1.0, 4095.5, 0.0, 1, 4095);
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(adc == 4095, "adc_r = adc_max+0.5 gave %d, expected 4095", adc);
    CHECK(g_ev_clip == 1, "adc_r = adc_max+0.5 raised %d clip events, expected 1",
          g_ev_clip);

    /* Bottom rail: a big negative noise sample must clamp to 0, never wrap
     * negative into the unsigned ADC field. */
    ev_clear();
    photonics_ring_config(h, 0.0, 512.0, 1.0, 0.0, 10.0, 1, 4095);
    adc = photonics_ring_step(h, 0, -1000.0, &d, &t);
    CHECK(adc == 0, "negative sample gave %d, expected the 0 rail", adc);
    CHECK(g_ev_clip == 0,
          "bottom rail raised %d clip events (only adc_max clips are reported)",
          g_ev_clip);

    /* A negative p_peak is nonsense but must not produce a negative code. */
    photonics_ring_config(h, 0.0, 512.0, 1.0, -500.0, 0.0, 1, 4095);
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(adc == 0, "negative p_peak gave %d, expected 0", adc);

    /* Rounding is round-to-nearest, matching $rtoi(x + 0.5). */
    photonics_ring_config(h, 0.0, 512.0, 1.0, 100.4, 0.0, 1, 4095);
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(adc == 100, "100.4 rounded to %d, expected 100", adc);
    photonics_ring_config(h, 0.0, 512.0, 1.0, 100.5, 0.0, 1, 4095);
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(adc == 101, "100.5 rounded to %d, expected 101", adc);

    photonics_ring_free(h);
    end();
}

/* --- 5. dark ring (laser_on = 0) --------------------------------------- */

static void test_dark_ring(void)
{
    void  *h;
    double d = 0.0;
    double t = 0.0;
    int    adc;

    begin("laser_on=0: dark ring, noise only");
    ev_clear();

    h = photonics_ring_new();
    photonics_ring_config(h, 1000.0, 512.0, 1.0, 3000.0, 0.0, 0, 4095);
    photonics_ring_reset(h);

    /* Sitting exactly on resonance, but the fibre is dark. */
    adc = photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(adc == 0, "dark ring on resonance gave adc %d, expected 0", adc);
    CHECK(d == 0.0, "dark ring lost the detuning: %.17g", d);
    CHECK(t == 1000.0, "dark ring stopped the heater: temp %.17g", t);

    /* The ADC then reads noise only -- this is what makes the MINPOW
     * false-lock guard (spec 3.4) testable. */
    photonics_ring_config(h, 1000.0, 512.0, 1.0, 3000.0, 50.0, 0, 4095);
    adc = photonics_ring_step(h, 1000, 20.0, &d, &t);
    CHECK(adc == 20, "dark ring with +20 LSB noise gave %d, expected 20", adc);
    adc = photonics_ring_step(h, 1000, -20.0, &d, &t);
    CHECK(adc == 0, "dark ring with -20 LSB noise gave %d, expected 0", adc);

    /* Relight it: the very next sample is bright again. */
    photonics_ring_config(h, 1000.0, 512.0, 1.0, 3000.0, 0.0, 1, 4095);
    adc = photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(adc == 3000, "relit ring gave %d, expected 3000", adc);

    CHECK(g_ev_clip == 0, "dark ring raised %d clip events", g_ev_clip);
    photonics_ring_free(h);
    end();
}

/* --- 6. noise gating (bit-exactness against uniform_noise()) ----------- */

static void test_noise_gating(void)
{
    void  *h;
    double d = 0.0;
    double t = 0.0;
    int    adc;

    begin("noise: gated by noise_lsb, never generated here");
    ev_clear();

    h = photonics_ring_new();

    /* noise_lsb <= 0 -> the sample is ignored, exactly as ring_model.sv's
     * uniform_noise() returns 0.0 for amp <= 0.0. */
    photonics_ring_config(h, 0.0, 512.0, 1.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    adc = photonics_ring_step(h, 0, 500.0, &d, &t);
    CHECK(adc == 3000, "noise_lsb=0 still injected noise: adc %d, expected 3000",
          adc);

    /* noise_lsb > 0 -> the caller's already-scaled sample is added verbatim. */
    photonics_ring_config(h, 0.0, 512.0, 1.0, 3000.0, 600.0, 1, 4095);
    adc = photonics_ring_step(h, 0, 500.0, &d, &t);
    CHECK(adc == 3500, "noise sample not added: adc %d, expected 3500", adc);
    adc = photonics_ring_step(h, 0, -500.0, &d, &t);
    CHECK(adc == 2500, "negative noise not added: adc %d, expected 2500", adc);

    /* Determinism: the model itself holds no RNG state, so identical inputs
     * give identical outputs forever. */
    adc = photonics_ring_step(h, 0, 250.0, &d, &t);
    CHECK(adc == 3250, "first repeat sample %d, expected 3250", adc);
    adc = photonics_ring_step(h, 0, 250.0, &d, &t);
    CHECK(adc == 3250, "second repeat sample %d, expected 3250 (no hidden RNG)",
          adc);

    photonics_ring_free(h);
    end();
}

/* --- 7. degenerate configuration --------------------------------------- */

static void test_degenerate_config(void)
{
    void  *h;
    double d = 0.0;
    double t = 0.0;
    int    adc;
    int    i;
    int    bad = 0;

    begin("degenerate config: clamped, finite, no crash");
    ev_clear();

    h = photonics_ring_new();

    /* tau <= 0 clamps to 1.0 (ring_model.sv clamps tau < 1.0). */
    photonics_ring_config(h, 0.0, 512.0, 0.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    (void)photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(t == 1000.0, "tau=0 gave temp %.17g, expected the tau=1 clamp (1000)", t);

    photonics_ring_config(h, 0.0, 512.0, -5.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    (void)photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(t == 1000.0, "tau=-5 gave temp %.17g, expected the tau=1 clamp", t);

    /* 0 < tau < 1 is the interesting band: it is not a divide-by-zero, so a
     * "guard against tau <= 0" implementation lets it through -- and the
     * discrete lag then OVERSHOOTS the drive (temp = 2000 for tau = 0.5),
     * which is unphysical. ring_model.sv clamps at 1.0, so this does too. */
    photonics_ring_config(h, 0.0, 512.0, 0.5, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    (void)photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(t == 1000.0,
          "tau=0.5 gave temp %.17g, expected 1000 (clamped to 1.0, no overshoot)",
          t);

    /* fwhm <= 0 clamps to 1.0: at d = 0.5 that is exactly the half-power
     * point of a 1-code-wide line. No division by zero, no inf. */
    photonics_ring_config(h, 999.5, 0.0, 1.0, 4000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    adc = photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(adc == 2000, "fwhm=0 gave adc %d, expected 2000 (fwhm clamped to 1)",
          adc);
    CHECK(isfinite(d) && isfinite(t), "fwhm=0 produced non-finite outputs");

    photonics_ring_config(h, 999.5, -3.0, 1.0, 4000.0, 0.0, 1, 4095);
    adc = photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(adc == 2000, "fwhm=-3 gave adc %d, expected 2000", adc);

    /* Same sub-unit band for fwhm: 0.5 divides fine but is narrower than one
     * DAC code, which no ring can be resolved at. Clamped to 1.0 like the SV
     * model; without the clamp this reads 800, not 2000. */
    photonics_ring_config(h, 999.5, 0.5, 1.0, 4000.0, 0.0, 1, 4095);
    adc = photonics_ring_step(h, 1000, 0.0, &d, &t);
    CHECK(adc == 2000, "fwhm=0.5 gave adc %d, expected 2000 (clamped to 1)", adc);

    /* adc_max <= 0 clamps to 1: a degenerate but well-defined 1-bit ADC. */
    photonics_ring_config(h, 0.0, 512.0, 1.0, 3000.0, 0.0, 1, 0);
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(adc == 1, "adc_max=0 gave adc %d, expected the clamped rail 1", adc);
    photonics_ring_config(h, 0.0, 512.0, 1.0, 3000.0, 0.0, 1, -7);
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(adc == 1, "adc_max=-7 gave adc %d, expected 1", adc);

    /* Non-finite parameters must be replaced, not propagated. */
    photonics_ring_config(h, NAN, INFINITY, -INFINITY, NAN, NAN, 1, 4095);
    photonics_ring_reset(h);
    for (i = 0; i < 50; i++) {
        adc = photonics_ring_step(h, 4095, 0.0, &d, &t);
        if (!isfinite(d) || !isfinite(t) || adc < 0 || adc > 4095) {
            bad++;
        }
    }
    CHECK(bad == 0, "%d of 50 steps with NaN/inf config produced bad output "
                    "(d=%g t=%g adc=%d)", bad, d, t, adc);

    /* A non-finite noise sample is a per-step argument, not config. */
    photonics_ring_config(h, 0.0, 512.0, 1.0, 3000.0, 10.0, 1, 4095);
    photonics_ring_reset(h);
    adc = photonics_ring_step(h, 0, NAN, &d, &t);
    CHECK(adc == 3000, "NaN noise sample gave adc %d, expected 3000 (ignored)",
          adc);
    adc = photonics_ring_step(h, 0, INFINITY, &d, &t);
    CHECK(adc == 3000, "inf noise sample gave adc %d, expected 3000 (ignored)",
          adc);
    CHECK(isfinite(d) && isfinite(t), "non-finite noise poisoned the state");

    /* A ring that was never configured at all still behaves (ring_if.sv
     * defaults: res 2048, fwhm 512, tau 4, p_peak 3000, 12-bit). */
    photonics_ring_free(h);
    h = photonics_ring_new();
    photonics_ring_reset(h);
    adc = run_n(h, 2048, 200, &d, &t);
    CHECK(adc == 3000, "unconfigured ring driven to res gave %d, expected 3000",
          adc);
    photonics_ring_free(h);

    end();
}

/* --- 8. resonance-crossing event --------------------------------------- */

static void test_crossing_event(void)
{
    void  *h;
    double d = 0.0;
    double t = 0.0;

    begin("event: one resonance cross per crossing");

    h = photonics_ring_new();
    photonics_ring_config(h, 1000.0, 512.0, 4.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);

    /* Sweep up through the resonance: exactly one crossing. */
    ev_clear();
    (void)run_n(h, 2000, 200, &d, &t);
    CHECK(g_ev_cross == 1, "sweep up raised %d cross events, expected 1",
          g_ev_cross);
    CHECK(g_ev_last_cross > 0.0,
          "upward crossing reported detune %g, expected > 0", g_ev_last_cross);
    CHECK(g_ev_clip == 0, "sweep up raised %d clip events, expected 0",
          g_ev_clip);

    /* Sweep back down: exactly one more. */
    ev_clear();
    (void)run_n(h, 0, 400, &d, &t);
    CHECK(g_ev_cross == 1, "sweep down raised %d cross events, expected 1",
          g_ev_cross);
    CHECK(g_ev_last_cross < 0.0,
          "downward crossing reported detune %g, expected < 0", g_ev_last_cross);

    /* Staying put below resonance: no further events. */
    ev_clear();
    (void)run_n(h, 0, 100, &d, &t);
    CHECK(g_ev_cross == 0, "idling below resonance raised %d cross events",
          g_ev_cross);

    /* Never reaching the resonance: no events at all. */
    photonics_ring_config(h, 3000.0, 512.0, 4.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    ev_clear();
    (void)run_n(h, 2000, 300, &d, &t);
    CHECK(g_ev_cross == 0, "a sweep that never reaches resonance raised %d "
                           "cross events", g_ev_cross);

    /* Landing EXACTLY on d == 0.0 and then continuing through is ONE crossing,
     * not zero (sign never flipped in a single step) and not two. */
    photonics_ring_config(h, 1000.0, 512.0, 1.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);
    ev_clear();
    (void)photonics_ring_step(h, 1000, 0.0, &d, &t); /* d == 0 exactly */
    CHECK(d == 0.0, "expected to land exactly on resonance, got %.17g", d);
    CHECK(g_ev_cross == 0, "landing on d==0 raised %d cross events, expected 0",
          g_ev_cross);
    (void)photonics_ring_step(h, 2000, 0.0, &d, &t); /* d > 0 */
    CHECK(g_ev_cross == 1, "leaving d==0 upward raised %d cross events, "
                           "expected 1 for the whole traversal", g_ev_cross);

    /* Reset re-arms the detector against the post-reset detuning. */
    photonics_ring_reset(h);
    ev_clear();
    (void)photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(d == -1000.0, "post-reset detune is %.17g, expected -res_code", d);
    CHECK(t == 0.0, "post-reset temp is %.17g, expected 0 (cold heater)", t);
    CHECK(g_ev_cross == 0, "reset itself raised %d cross events", g_ev_cross);

    photonics_ring_free(h);
    end();
}

/* --- 9. instance independence ------------------------------------------ */

static void test_multi_instance(void)
{
    void  *h1;
    void  *h2;
    double d = 0.0;
    double t = 0.0;
    int    a1;
    int    a2;

    begin("handles: instances are independent");
    ev_clear();

    h1 = photonics_ring_new();
    h2 = photonics_ring_new();
    photonics_ring_config(h1, 1000.0, 512.0, 1.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_config(h2, 3000.0, 512.0, 1.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h1);
    photonics_ring_reset(h2);

    a1 = photonics_ring_step(h1, 1000, 0.0, &d, &t);
    a2 = photonics_ring_step(h2, 1000, 0.0, &d, &t);
    CHECK(a1 == 3000, "ring 1 on resonance gave %d, expected 3000", a1);
    CHECK(a2 < 100, "ring 2 far off resonance gave %d, expected a dark sample",
          a2);

    /* Stepping ring 2 must not have disturbed ring 1's thermal state. */
    a1 = photonics_ring_step(h1, 1000, 0.0, &d, &t);
    CHECK(a1 == 3000, "ring 1 changed after ring 2 was stepped: %d", a1);
    CHECK(t == 1000.0, "ring 1 temp is %.17g, expected 1000", t);

    /* Freeing one leaves the other usable. */
    photonics_ring_free(h2);
    a1 = photonics_ring_step(h1, 1000, 0.0, &d, &t);
    CHECK(a1 == 3000, "ring 1 broke after ring 2 was freed: %d", a1);
    photonics_ring_free(h1);

    end();
}

/* --- 10. reset really clears the heater -------------------------------- */

/* Every other reset in this file uses tau = 1 (where the lag is a pass-through
 * and the first post-reset sample lands on dac_code either way) or resets a
 * ring that was already cold. Both are blind to a reset that forgets
 * `temp = 0.0`. This section is not: it resets a HOT ring with a slow tau, so
 * the leftover thermal state would be visible on the very next sample.
 *
 * Why it matters beyond the C model: ring_model.sv re-resets the handle on
 * every reset edge while dac_code is driven to 0. A C model that stayed hot
 * across reset would disagree with the SV model from the first post-reset
 * sample onwards, and the equivalence run would mismatch every cycle. */
static void test_reset_clears_thermal_state(void)
{
    void  *h;
    double d = 0.0;
    double t = 0.0;
    int    adc;

    begin("reset: clears a HOT heater, not just a cold one");
    ev_clear();

    h = photonics_ring_new();
    /* tau = 8: the lag needs several cycles, so a stale temp cannot be washed
     * out by the single post-reset step below. */
    photonics_ring_config(h, 1000.0, 512.0, 8.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);

    /* Heat it right up to the resonance and confirm it really got there --
     * otherwise the reset below would have nothing to clear. */
    adc = run_n(h, 1000, 400, &d, &t);
    CHECK(close_to(t, 1000.0, 1e-9),
          "setup failed: ring did not heat, temp %.17g", t);
    CHECK(adc == 3000, "setup failed: hot ring reads %d, expected 3000", adc);

    photonics_ring_reset(h);
    ev_clear();

    /* One step at dac_code = 0 from a genuinely cold ring:
     *     temp = 0 + (0 - 0)/8 = 0   EXACTLY.
     * A reset that left temp at 1000 gives 1000 - 1000/8 = 875 here, and an
     * ADC of 2422 instead of 185. */
    adc = photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(t == 0.0, "temp after reset+step is %.17g, expected 0 exactly "
                    "(875 means reset did not clear the heater)", t);
    CHECK(d == -1000.0, "detune after reset+step is %.17g, expected -res_code "
                        "(-1000)", d);
    CHECK(adc == 185, "post-reset ADC is %d, expected 185 (a cold, far "
                      "off-resonance ring)", adc);
    CHECK(g_ev_cross == 0, "reset raised %d cross events, expected 0",
          g_ev_cross);

    /* Same again with the laser off and a different tau, so the check does not
     * depend on one operating point. */
    photonics_ring_config(h, 4095.0, 512.0, 4.0, 3000.0, 0.0, 0, 4095);
    (void)run_n(h, 4000, 200, &d, &t);
    CHECK(close_to(t, 4000.0, 1e-9), "setup failed: temp %.17g, expected 4000", t);
    photonics_ring_reset(h);
    (void)photonics_ring_step(h, 0, 0.0, &d, &t);
    CHECK(t == 0.0, "temp after reset+step is %.17g, expected 0 exactly "
                    "(3000 means reset did not clear the heater)", t);

    photonics_ring_free(h);
    end();
}

/* --- 11. config must NOT disturb the thermal integrator ----------------- */

/* The single most load-bearing invariant in this layer, and the one a naive
 * "reset the model when its parameters change" reflex breaks:
 * ring_model.sv re-publishes the whole parameter set through ring_dpi_config
 * BEFORE EVERY STEP. If _config cleared temp, the integrator would restart from
 * cold on every cycle, the thermal lag would vanish, and the DUT would never
 * lock -- while every existing check in this file still passed. It is normative
 * in photonics_dpi.h ("Does not disturb thermal state"). */
static void test_config_preserves_state(void)
{
    void  *h;
    void  *h_ref;
    double d  = 0.0;
    double t  = 0.0;
    double d2 = 0.0;
    double t2 = 0.0;
    double t_before;
    double expect;
    int    a_ref;
    int    a_cfg;
    int    i;
    int    diff = 0;

    begin("config: mid-run reconfig keeps the integrator");
    ev_clear();

    h = photonics_ring_new();
    photonics_ring_config(h, 0.0, 512.0, 8.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h);

    /* Charge the integrator part-way -- deliberately mid-scale, so both a
     * cleared temp (0) and a saturated one are distinguishable. */
    (void)run_n(h, 1000, 4, &d, &t);
    t_before = t;
    CHECK(close_to(t_before, 1000.0 * (1.0 - pow(7.0 / 8.0, 4.0)), 1e-9),
          "setup failed: temp after 4 steps is %.17g", t_before);
    CHECK(t_before > 100.0 && t_before < 900.0,
          "setup failed: temp %.17g is not mid-charge", t_before);

    /* Reconfigure EVERYTHING else mid-run, keeping tau > 1 so the lag is still
     * observable. The next step must continue the integration from t_before,
     * not restart from cold. */
    photonics_ring_config(h, 2000.0, 256.0, 8.0, 4000.0, 0.0, 1, 4095);
    (void)photonics_ring_step(h, 1000, 0.0, &d, &t);
    expect = t_before + (1000.0 - t_before) / 8.0;
    CHECK(close_to(t, expect, 1e-9),
          "temp after reconfig is %.17g, expected %.17g (125 means _config "
          "cleared the integrator)", t, expect);
    CHECK(t > t_before, "reconfig moved the heater backwards: %.17g -> %.17g",
          t_before, t);

    /* A tau change mid-run must change the RATE, not the accumulated state. */
    t_before = t;
    photonics_ring_config(h, 2000.0, 256.0, 2.0, 4000.0, 0.0, 1, 4095);
    (void)photonics_ring_step(h, 1000, 0.0, &d, &t);
    expect = t_before + (1000.0 - t_before) / 2.0;
    CHECK(close_to(t, expect, 1e-9),
          "temp after a tau change is %.17g, expected %.17g", t, expect);
    photonics_ring_free(h);

    /* The strongest form, and exactly how ring_model.sv drives this layer: a
     * ring reconfigured with identical parameters before every single step must
     * trace the SAME trajectory, bit for bit, as one configured only once. */
    h_ref = photonics_ring_new();
    h     = photonics_ring_new();
    photonics_ring_config(h_ref, 1200.0, 512.0, 8.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_config(h,     1200.0, 512.0, 8.0, 3000.0, 0.0, 1, 4095);
    photonics_ring_reset(h_ref);
    photonics_ring_reset(h);

    for (i = 0; i < 60; i++) {
        photonics_ring_config(h, 1200.0, 512.0, 8.0, 3000.0, 0.0, 1, 4095);
        a_ref = photonics_ring_step(h_ref, 1500, 0.0, &d,  &t);
        a_cfg = photonics_ring_step(h,     1500, 0.0, &d2, &t2);
        if (t2 != t || d2 != d || a_cfg != a_ref) {
            if (diff == 0) {
                printf("   [note] step %d: temp %.17g vs %.17g, adc %d vs %d\n",
                       i, t, t2, a_ref, a_cfg);
            }
            diff++;
        }
    }
    CHECK(diff == 0, "%d of 60 steps diverged when the ring was reconfigured "
                     "every cycle (per-step _config must be a no-op for state)",
          diff);
    /* Prove the comparison had something to compare: the reference really did
     * integrate up to (near) its drive, so a per-step _config that pinned temp
     * at 1500/8 = 187.5 could not have passed the loop above by accident. */
    CHECK(t > 1400.0,
          "setup failed: reference ring only reached temp %.17g, expected it to "
          "integrate up to ~1500", t);

    photonics_ring_free(h);
    photonics_ring_free(h_ref);
    end();
}

/* --- main --------------------------------------------------------------- */

int main(void)
{
    printf("photonics DPI-C model unit tests -- %s\n", photonics_dpi_version());
    printf("(no simulator involved; sv_ring_event is a local stub)\n");
    printf("note: the degenerate-config section prints expected clamp warnings "
           "on stderr\n\n");

    test_abi_hygiene();
    test_lorentzian();
    test_thermal_lag();
    test_adc_clamp();
    test_dark_ring();
    test_noise_gating();
    test_degenerate_config();
    test_crossing_event();
    test_multi_instance();
    test_reset_clears_thermal_state();
    test_config_preserves_state();

    printf("\n");
    if (g_tot_fails == 0) {
        printf("PASS: %d checks in %d sections, 0 failures\n",
               g_tot_checks, g_sections);
        return 0;
    }
    printf("FAIL: %d of %d checks failed (%d of %d sections)\n",
           g_tot_fails, g_tot_checks, g_sections_failed, g_sections);
    return 1;
}
