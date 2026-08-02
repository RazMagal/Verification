/* ---------------------------------------------------------------------------
 * photonics_dpi.c : microring + photodiode + ADC, in C, for DPI-C export.
 *
 *   Mirrors ip/photonic_ring_tuner/dv/optics/ring_model.sv equation for
 *   equation AND in the same evaluation order (spec 7.2): thermal lag, then
 *   detuning, then Lorentzian, then photodiode -> ADC quantize + clamp. The
 *   order matters: the ADC sample a step returns is produced by the temp this
 *   step just computed, not by last step's temp. Reordering changes the loop's
 *   phase by one clock and silently breaks the settle/tau ratio that spec 7.6
 *   builds its headline coverage cross on.
 *
 *   Floating point: both models use IEEE-754 doubles (SV `real` IS a double)
 *   and identical parenthesisation, so a sample-by-sample bit comparison
 *   between this file and ring_model.sv is meaningful and is the acceptance
 *   test for the port.
 *
 * WHY THE RNG STAYS IN SYSTEMVERILOG
 *   ring_model.sv draws its read noise with $urandom_range, i.e. from the
 *   simulator's seed domain, so every run reproduces exactly from the UVM seed
 *   (+ntb_random_seed / -sv_seed / -svseed). If this C layer called rand() or
 *   random() instead, the noise would come from libc's generator, which the
 *   simulator neither seeds nor records: two runs of the same seed would then
 *   diverge and a failing regression could not be replayed. That is fatal for
 *   DV, so noise is drawn and scaled in SV and passed IN as an argument. This
 *   file contains no RNG at all -- deliberately.
 *
 * REENTRANCY
 *   sv_ring_event() is a callback INTO the simulator, which may run arbitrary
 *   SV (and could in principle re-enter this model). Every event is therefore
 *   emitted at the very end of a step, after the handle's state and the output
 *   arguments have been committed. The SV import of photonics_ring_step must
 *   be declared `context` (see photonics_dpi.h).
 * ------------------------------------------------------------------------- */
#include "photonics_dpi.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define PHOTONICS_DPI_VERSION_STR "photonics_dpi 1.0.0"

/* One "not finite" warning slot per configurable double. A single shared flag
 * would let the FIRST bad parameter consume the only warning, so a later NaN --
 * say p_peak_lsb, which silently becomes 0.0 and darkens the ADC for the whole
 * run -- would be substituted with no diagnostic at all. Diagnose each one. */
enum {
    NF_RES_CODE = 0,
    NF_FWHM_CODE,
    NF_TAU_CYCLES,
    NF_P_PEAK_LSB,
    NF_NOISE_LSB,
    NF_COUNT
};

/* Opaque to SystemVerilog: SV only ever holds this as a `chandle`. */
struct photonics_ring {
    /* ---- physical configuration (spec 7.4) ---- */
    double res_code;   /* thermal state (DAC codes) that aligns the ring   */
    double fwhm_code;  /* resonance linewidth, DAC codes                   */
    double tau_cycles; /* thermal time constant, CLOCK CYCLES (spec 7.3)   */
    double p_peak_lsb; /* ADC reading at perfect alignment                 */
    double noise_lsb;  /* uniform ADC noise amplitude, LSBs               */
    int    laser_on;   /* 0 => trans forced to 0 (dark fibre)             */
    int    adc_max;    /* 2**ADC_WIDTH - 1 (a localparam in the SV model)  */

    /* ---- state ---- */
    double temp;      /* thermal state, DAC codes                          */
    int    sign_lat;  /* -1/0/+1: sign of the last NON-ZERO detuning       */

    /* ---- one-shot warning flags (mirror warned_tau / warned_fwhm) ---- */
    int warned_tau;
    int warned_fwhm;
    int warned_adc;
    int warned_nonfinite[NF_COUNT];
};

/* --- helpers ------------------------------------------------------------ */

/* Round-to-nearest + clamp into the ADC's unsigned range. Mirrors the SV
 * quantize(): `if (adc_in <= 0.0) return 0; q = $rtoi(adc_in + 0.5);` --
 * $rtoi truncates toward zero, which for a positive argument is floor(), so
 * (int)(v + 0.5) is the identical operation.
 *
 * *clipped reports SATURATION, not "the output happens to equal adc_max": a
 * sample of adc_max - 0.2 rounds up to adc_max without the clamp ever
 * engaging, and calling that a clip would make the event useless as a
 * headroom warning. The bottom rail is intentionally NOT reported -- on a dark
 * ring negative noise clamps to 0 on most samples, so an event there would
 * fire continuously and tell the scoreboard nothing. */
static int quantize(double adc_in, int adc_max, int *clipped)
{
    int q;

    *clipped = 0;

    /* NaN compares false against everything, including the <= 0.0 test below,
     * and would then reach the cast -- which is undefined behaviour in C. Trap
     * it first. Configuration is sanitised (below) so this is unreachable in
     * practice; it is here because a UB cast is not an acceptable residual
     * risk in a model that runs inside somebody's simulator. */
    if (isnan(adc_in)) {
        return 0;
    }
    if (adc_in <= 0.0) {
        return 0;
    }
    /* Also catches +inf. Anything at or above adc_max + 0.5 rounds past the
     * top code, so the clamp is what produced the result. */
    if (adc_in >= (double)adc_max + 0.5) {
        *clipped = 1;
        return adc_max;
    }
    q = (int)(adc_in + 0.5);
    if (q > adc_max) { /* belt and braces against a double-rounding edge */
        *clipped = 1;
        return adc_max;
    }
    return q;
}

static int sgn(double v)
{
    if (v > 0.0) { return 1; }
    if (v < 0.0) { return -1; }
    return 0;
}

/* SV `real` can hold inf/NaN and the DV never generates them, but a chandle
 * ABI is reachable from any C caller (including these unit tests). A NaN
 * parameter would poison temp for the rest of the run, so it is replaced at
 * configuration time rather than left to propagate.
 *
 * `warned` is the caller's PER-PARAMETER flag, not a shared one: substituting a
 * value silently is only acceptable because it is always announced once. */
static double sane(int *warned, double v, double fallback, const char *what)
{
    if (isfinite(v)) {
        return v;
    }
    if (!*warned) {
        *warned = 1;
        fprintf(stderr,
                "photonics_dpi: %s is not finite, using %g instead\n",
                what, fallback);
    }
    return fallback;
}

/* --- ABI ---------------------------------------------------------------- */

void *photonics_ring_new(void)
{
    struct photonics_ring *h =
        (struct photonics_ring *)malloc(sizeof(struct photonics_ring));
    int i;

    if (h == NULL) {
        return NULL; /* SV sees a null chandle; every entry point tolerates it */
    }

    /* Benign, lockable ring -- the initialisers in ring_if.sv. */
    h->res_code   = 2048.0;
    h->fwhm_code  = 512.0;
    h->tau_cycles = 4.0;
    h->p_peak_lsb = 3000.0;
    h->noise_lsb  = 0.0;
    h->laser_on   = 1;
    h->adc_max    = 4095; /* 12-bit, the spec 1 default */

    h->temp     = 0.0;
    h->sign_lat = sgn(-h->res_code);

    h->warned_tau  = 0;
    h->warned_fwhm = 0;
    h->warned_adc  = 0;
    for (i = 0; i < NF_COUNT; i++) {
        h->warned_nonfinite[i] = 0;
    }

    return (void *)h;
}

void photonics_ring_free(void *h)
{
    free(h); /* free(NULL) is defined to do nothing */
}

void photonics_ring_config(void *h_, double res_code, double fwhm_code,
                           double tau_cycles, double p_peak_lsb,
                           double noise_lsb, int laser_on, int adc_max)
{
    struct photonics_ring *h = (struct photonics_ring *)h_;

    if (h == NULL) {
        return;
    }

    h->res_code   = sane(&h->warned_nonfinite[NF_RES_CODE],
                         res_code,   0.0, "res_code");
    h->fwhm_code  = sane(&h->warned_nonfinite[NF_FWHM_CODE],
                         fwhm_code,  PHOTONICS_FWHM_MIN, "fwhm_code");
    h->tau_cycles = sane(&h->warned_nonfinite[NF_TAU_CYCLES],
                         tau_cycles, PHOTONICS_TAU_MIN,  "tau_cycles");
    h->p_peak_lsb = sane(&h->warned_nonfinite[NF_P_PEAK_LSB],
                         p_peak_lsb, 0.0, "p_peak_lsb");
    h->noise_lsb  = sane(&h->warned_nonfinite[NF_NOISE_LSB],
                         noise_lsb,  0.0, "noise_lsb");
    h->laser_on   = (laser_on != 0);
    h->adc_max    = adc_max;

    /* Thermal state and the crossing latch are NOT touched: a mid-test config
     * change (spec 7.4 allows one -- e.g. the laser being switched off) must
     * not teleport the heater. If a config move puts res_code on the other
     * side of the current temp, the next step legitimately reports a
     * resonance crossing, because the detuning really did change sign.
     *
     * This is load-bearing, not a nicety: ring_model.sv re-publishes the whole
     * parameter set through ring_dpi_config on EVERY step, so a `h->temp = 0.0`
     * here would kill the thermal lag outright and the DUT would never lock.
     * test_config_preserves_state() in test/ pins it down. */
}

void photonics_ring_reset(void *h_)
{
    struct photonics_ring *h = (struct photonics_ring *)h_;

    if (h == NULL) {
        return;
    }

    /* dac_code drives 0 through reset (spec 1), so the heater is cold. Clearing
     * temp is load-bearing: ring_model.sv re-resets the handle on every reset
     * edge, so a C model that stayed hot across reset would disagree with the
     * SV model on the very next sample and mismatch every cycle after it.
     * test_reset_clears_thermal_state() pins it down. */
    h->temp = 0.0;
    /* Re-arm the crossing detector against the post-reset detuning
     * (d = temp - res_code = -res_code). Reset itself is not a crossing and
     * emits no event. */
    h->sign_lat = sgn(-h->res_code);
}

int photonics_ring_step(void *h_, int dac_code, double noise_sample,
                        double *detune_code, double *temp_code)
{
    struct photonics_ring *h = (struct photonics_ring *)h_;
    double tau;
    double fwhm;
    double d;
    double x;
    double trans;
    double noise;
    double adc_r;
    int    adc_max;
    int    adc;
    int    clipped;
    int    crossed;
    int    s;

    if (h == NULL) {
        if (detune_code != NULL) { *detune_code = 0.0; }
        if (temp_code   != NULL) { *temp_code   = 0.0; }
        return 0;
    }

    /* Defensive guards, identical to ring_model.sv's: the DV constrains
     * tau_cycles >= 1.0 and fwhm_code >= 1, so these only fire if someone
     * configures the model by hand. Clamped per step (not rewritten in
     * _config) so the SV and C models clamp at the same point in time and a
     * bit comparison of a deliberately-degenerate run still matches. */
    tau = h->tau_cycles;
    if (tau < PHOTONICS_TAU_MIN) {
        if (!h->warned_tau) {
            h->warned_tau = 1;
            fprintf(stderr, "photonics_dpi: tau_cycles=%0.3f < %0.1f, clamped\n",
                    tau, PHOTONICS_TAU_MIN);
        }
        tau = PHOTONICS_TAU_MIN;
    }
    fwhm = h->fwhm_code;
    if (fwhm < PHOTONICS_FWHM_MIN) {
        if (!h->warned_fwhm) {
            h->warned_fwhm = 1;
            fprintf(stderr, "photonics_dpi: fwhm_code=%0.3f < %0.1f, clamped\n",
                    fwhm, PHOTONICS_FWHM_MIN);
        }
        fwhm = PHOTONICS_FWHM_MIN;
    }
    /* adc_max is a localparam in the SV model and cannot go bad there; over
     * DPI it is an argument, so it can. An ADC with no codes would make the
     * clamp order (0 .. adc_max) inverted. */
    adc_max = h->adc_max;
    if (adc_max < PHOTONICS_ADC_MAX_MIN) {
        if (!h->warned_adc) {
            h->warned_adc = 1;
            fprintf(stderr, "photonics_dpi: adc_max=%d < %d, clamped\n",
                    adc_max, PHOTONICS_ADC_MAX_MIN);
        }
        adc_max = PHOTONICS_ADC_MAX_MIN;
    }

    /* 1st-order thermal lag toward the commanded heater code. */
    h->temp = h->temp + ((double)dac_code - h->temp) / tau;

    /* Detuning and Lorentzian transmission (0 with the laser off). */
    d     = h->temp - h->res_code;
    x     = 2.0 * d / fwhm;
    trans = h->laser_on ? (1.0 / (1.0 + x * x)) : 0.0;

    /* Photodiode -> ADC. The noise sample is gated by noise_lsb <= 0 exactly
     * as ring_model.sv's uniform_noise() gates on amp <= 0.0 -- without this,
     * a testbench that scales its own sample would inject noise into a run
     * configured for none, and the C/SV bit comparison would fail. */
    noise = (h->noise_lsb > 0.0) ? noise_sample : 0.0;
    if (!isfinite(noise)) {
        noise = 0.0; /* per-step argument: not covered by _config's sanitising */
    }
    adc_r = h->p_peak_lsb * trans + noise;
    adc   = quantize(adc_r, adc_max, &clipped);

    /* Resonance crossing: compare against the last NON-ZERO sign, so a step
     * that lands exactly on d == 0.0 and a later step that leaves it report
     * ONE crossing between them, not zero and not two. */
    s       = sgn(d);
    crossed = (s != 0 && h->sign_lat != 0 && s != h->sign_lat);
    if (s != 0) {
        h->sign_lat = s;
    }

    /* Commit state and outputs BEFORE any callback into SV (see file header).
     * The detuning is published through the output argument only; the handle
     * deliberately does not cache it, because nothing reads a cached copy and a
     * second home for the same value is a place for the two to disagree. */
    if (detune_code != NULL) { *detune_code = d; }
    if (temp_code   != NULL) { *temp_code   = h->temp; }

    if (crossed) {
        sv_ring_event(PHOTONICS_EV_RESONANCE_CROSS, d);
    }
    if (clipped) {
        sv_ring_event(PHOTONICS_EV_ADC_CLIP, adc_r);
    }

    return adc;
}

const char *photonics_dpi_version(void)
{
    /* Static storage: SV copies a DPI string return immediately, but the
     * pointer must stay valid until it does. Never return a stack buffer. */
    return PHOTONICS_DPI_VERSION_STR;
}

/* --- standalone build only ----------------------------------------------- */
#ifdef PHOTONICS_DPI_STANDALONE
/* Compiled in ONLY by `make standalone`, which produces a SEPARATE artifact
 * (libphotonics_dpi_standalone.so) for consumers with no simulator underneath
 * them: a Python ctypes characterisation script, a fuzzer, a link-budget tool.
 *
 * WHY THIS IS A BUILD FLAG AND NOT A WEAK SYMBOL IN THE NORMAL LIBRARY
 *   The tempting shortcut is to make sv_ring_event weak in libphotonics_dpi.so
 *   so the file always links. Don't. Weak-symbol preemption depends on load
 *   order and on the simulator exporting its DPI symbols globally, which not
 *   every tool does -- and when preemption does not happen the model links
 *   cleanly, runs, and drops EVERY event on the floor. Spec 7.7(4) makes a
 *   silently dead event path a must-fail, and a must-fail that presents as
 *   "the scoreboard just never saw a crossing" costs days.
 *
 *   Keeping the two artifacts separate makes the failure mode impossible:
 *   libphotonics_dpi.so has an UNDEFINED sv_ring_event and can only be loaded
 *   by something that defines it (i.e. the simulator), and the standalone .so
 *   defines it strongly, so it can never accidentally be the one a simulator
 *   picks up.
 *
 * The counters below exist so a standalone consumer can still observe the
 * event path. They are NOT part of the frozen DPI ABI and do not exist in the
 * simulator artifact. */
static unsigned long g_standalone_ev[PHOTONICS_EV_ADC_CLIP + 1];

void sv_ring_event(int ev, double value)
{
    (void)value;
    if (ev >= 0 && ev <= PHOTONICS_EV_ADC_CLIP) {
        g_standalone_ev[ev]++;
    }
}

unsigned long photonics_standalone_event_count(int ev)
{
    if (ev < 0 || ev > PHOTONICS_EV_ADC_CLIP) {
        return 0UL;
    }
    return g_standalone_ev[ev];
}

void photonics_standalone_event_reset(void)
{
    int i;
    for (i = 0; i <= PHOTONICS_EV_ADC_CLIP; i++) {
        g_standalone_ev[i] = 0UL;
    }
}
#endif /* PHOTONICS_DPI_STANDALONE */
