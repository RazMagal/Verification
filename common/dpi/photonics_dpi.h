/* ---------------------------------------------------------------------------
 * photonics_dpi.h : C model of the microring + photodiode + ADC, exported to
 *                   SystemVerilog over DPI-C.
 *
 *   This is the C twin of ip/photonic_ring_tuner/dv/optics/ring_model.sv and
 *   implements the SAME equations in the SAME order (spec 7.2), so the two can
 *   be bit-compared sample-for-sample:
 *
 *     temp  <- temp + (real'(dac_code) - temp) / tau_cycles   // thermal lag
 *     d      = temp - res_code                                // detuning
 *     x      = 2.0 * d / fwhm_code
 *     trans  = laser_on ? 1.0 / (1.0 + x*x) : 0.0             // Lorentzian
 *     adc_r  = p_peak_lsb * trans + noise
 *     adc    = clamp(round(adc_r), 0, adc_max)
 *
 *   Everything is in DAC-code space and CLOCK CYCLES (spec 7.1 / 7.3).
 *
 *   WHY C: the photonics group ships the device model in C, not SystemVerilog.
 *   See README.md.
 *
 * DPI TYPE MAPPING (this is why the ABI uses only plain C scalars)
 *   SV chandle      <-> void*
 *   SV int          <-> int
 *   SV real         <-> double
 *   SV output real  <-> double*
 *   SV string       <-> const char*   (return value; SV copies it)
 *
 *   No svdpi.h type is required by the ABI. svdpi.h is included when a
 *   simulator provides one (it declares svScope/svSetScope etc. for anyone
 *   extending this layer), but the model builds and the unit tests run with
 *   plain gcc and no simulator installed. That is deliberate: the physics must
 *   be testable without a licence.
 * ------------------------------------------------------------------------- */
#ifndef PHOTONICS_DPI_H
#define PHOTONICS_DPI_H

/* Include svdpi.h when the build system points at a simulator's copy
 * (-DPHOTONICS_DPI_HAVE_SVDPI -I<sim>/include), or when it is simply on the
 * include path. Absent both, everything below still compiles. */
#if defined(PHOTONICS_DPI_HAVE_SVDPI)
#  include "svdpi.h"
#elif defined(__has_include)
#  if __has_include("svdpi.h")
#    include "svdpi.h"
#    define PHOTONICS_DPI_HAVE_SVDPI 1
#  endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* --- events reported to SystemVerilog via sv_ring_event() ---------------- */
#define PHOTONICS_EV_RESONANCE_CROSS 0 /* detune_code changed sign          */
#define PHOTONICS_EV_ADC_CLIP        1 /* quantizer clipped at adc_max      */

/* --- degenerate-config clamps (identical to ring_model.sv) --------------- */
#define PHOTONICS_TAU_MIN   1.0 /* tau  < 1 would make the discrete lag overshoot */
#define PHOTONICS_FWHM_MIN  1.0 /* fwhm < 1 divides by ~zero                      */
#define PHOTONICS_ADC_MAX_MIN 1 /* an ADC with no codes is not an ADC             */

/* --- the ABI -------------------------------------------------------------
 * Every entry point tolerates a NULL handle (returns a neutral value, never
 * dereferences). The handle is opaque and per-instance: no global holds model
 * state, so a testbench may instantiate as many rings as it likes.
 *
 * IMPORTANT (SV side): photonics_ring_step() can call BACK into SystemVerilog
 * through sv_ring_event(), so its SV import declaration MUST be `context`:
 *
 *     import "DPI-C" context function int photonics_ring_step(
 *         input chandle h, input int dac_code, input real noise_sample,
 *         output real detune_code, output real temp_code);
 *
 * A non-context import gives the callback no SV scope to run in; simulators
 * either error out or (worse) resolve the export against an arbitrary scope.
 * Declaring the other imports `context` too is harmless and keeps the block
 * uniform. The matching export must live in the scope that owns the ring:
 *
 *     export "DPI-C" function sv_ring_event;
 */

/* Allocate a ring instance. Returns NULL on allocation failure. The instance
 * starts with the benign, lockable defaults of ring_if.sv (res 2048, fwhm 512,
 * tau 4, p_peak 3000, no noise, laser on, 12-bit ADC) so a testbench that
 * forgets to call _config still simulates something sane. */
void* photonics_ring_new(void);

/* Release a ring instance. free(NULL) is a no-op, like C's. */
void photonics_ring_free(void* h);

/* Set the physical parameters (spec 7.4). Non-finite values are replaced by
 * safe defaults; tau/fwhm/adc_max are clamped per step, exactly like the SV
 * model, not silently rewritten here. Does not disturb thermal state. */
void photonics_ring_config(void* h, double res_code, double fwhm_code,
                           double tau_cycles, double p_peak_lsb,
                           double noise_lsb, int laser_on, int adc_max);

/* Cold reset: temp = 0, detune = -res_code, ADC = 0 (ring_model.sv's rst_n
 * branch). Re-arms the resonance-crossing detector against the current
 * res_code; no event is emitted for the reset itself. */
void photonics_ring_reset(void* h);

/* One clock's worth of update. Returns the quantized ADC code and writes the
 * live detuning / thermal state through the pointers (either may be NULL).
 *
 * noise_sample is the ADC read noise IN LSBs, ALREADY DRAWN AND SCALED BY
 * SYSTEMVERILOG. This layer never calls rand()/random(): see README.md and the
 * comment in photonics_dpi.c. It is ignored when noise_lsb <= 0, mirroring
 * ring_model.sv's uniform_noise(). */
int photonics_ring_step(void* h, int dac_code, double noise_sample,
                        double* detune_code, double* temp_code);

/* Version of this DPI layer, for a banner / a compatibility check in SV. */
const char* photonics_dpi_version(void);

/* IMPLEMENTED IN SYSTEMVERILOG (export "DPI-C"), called back from C.
 * ev is one of PHOTONICS_EV_*; value carries the new detune_code for a
 * resonance crossing and the unquantized adc_r for an ADC clip.
 *
 * It is therefore UNDEFINED in libphotonics_dpi.so, on purpose: that library is
 * only loadable by something that supplies the symbol (a simulator, or the unit
 * tests, which link their own stub). A consumer with no simulator -- a Python
 * ctypes script, say -- must load the SEPARATE artifact built by
 * `make standalone`, which links the stub below. Do NOT make this symbol weak
 * in the main library: a weak definition the simulator fails to preempt links
 * fine and then swallows every event, which spec 7.7(4) makes a must-fail. */
extern void sv_ring_event(int ev, double value);

/* --- standalone artifact only (libphotonics_dpi_standalone.so) -----------
 * NOT part of the frozen DPI ABI; these symbols do not exist in the library
 * the simulator loads. They let a simulator-less consumer see the event path
 * that SystemVerilog would otherwise be receiving. */
#ifdef PHOTONICS_DPI_STANDALONE
unsigned long photonics_standalone_event_count(int ev);
void          photonics_standalone_event_reset(void);
#endif

#ifdef __cplusplus
}
#endif

#endif /* PHOTONICS_DPI_H */
