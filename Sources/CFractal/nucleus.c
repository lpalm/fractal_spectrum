// Minibrot location tools for the quadratic Mandelbrot set: period detection, Newton nucleus search, size estimate.
#include <mpfr.h>
#include <math.h>
#include "internal.h"

// Lowest period whose atom domain intersects the disk |c - c0| < r (ball iteration: the image of the disk
// under z -> z^2 + c contains 0). Returns 0 when none is found within maxPeriod.
long fs_find_period(const FSHP *cre, const FSHP *cim, double log2r, long maxPeriod) {
    long prec = mpfr_get_prec(cre->value) + 16;
    mpfr_t x, y, t0, t1, t2, cx, cy;
    mpfr_inits2(prec, x, y, t0, t1, t2, cx, cy, (mpfr_ptr)0);
    mpfr_set(cx, cre->value, MPFR_RNDN);
    mpfr_set(cy, cim->value, MPFR_RNDN);
    mpfr_set_zero(x, 1);
    mpfr_set_zero(y, 1);
    // disk radius R_n tracked as log2: R_n = 2|z_{n-1}| R_{n-1} + R_{n-1}^2 + r, z_n = z_{n-1}^2 + c
    double lR = -1e300, lzPrev = -1e300;
    long found = 0;
    for (long n = 1; n <= maxPeriod; n++) {
        // log2 of the three terms of R_n, summed without overflow
        double a = 1 + lzPrev + lR, b = 2 * lR;
        double mx = fmax(a, fmax(b, log2r));
        lR = mx + log2(exp2(a - mx) + exp2(b - mx) + exp2(log2r - mx));
        mpfr_sqr(t0, x, MPFR_RNDN);
        mpfr_sqr(t1, y, MPFR_RNDN);
        mpfr_mul(t2, x, y, MPFR_RNDN);
        mpfr_mul_2ui(t2, t2, 1, MPFR_RNDN);
        mpfr_sub(x, t0, t1, MPFR_RNDN);
        mpfr_add(x, x, cx, MPFR_RNDN);
        mpfr_add(y, t2, cy, MPFR_RNDN);
        mpfr_hypot(t0, x, y, MPFR_RNDN);
        long ex;
        double m = mpfr_zero_p(t0) ? 0 : mpfr_get_d_2exp(&ex, t0, MPFR_RNDN);
        double lz = m == 0 ? -1e300 : log2(m) + ex;
        if (lz < lR) { found = n; break; }
        if (lz > 2 || lR > 2) break;
        lzPrev = lz;
    }
    mpfr_clears(x, y, t0, t1, t2, cx, cy, (mpfr_ptr)0);
    return found;
}

// Newton iteration for a nucleus of the given period starting at (cre, cim); writes the result
// into (outRe, outIm). Returns the number of Newton steps taken, or -1 on failure.
long fs_find_nucleus(const FSHP *cre, const FSHP *cim, long period, long maxSteps, FSHP *outRe, FSHP *outIm) {
    long prec = mpfr_get_prec(outRe->value);
    mpfr_t cx, cy, x, y, dx, dy, t0, t1, t2, nx, ny, den;
    mpfr_inits2(prec, cx, cy, x, y, dx, dy, t0, t1, t2, nx, ny, den, (mpfr_ptr)0);
    mpfr_set(cx, cre->value, MPFR_RNDN);
    mpfr_set(cy, cim->value, MPFR_RNDN);
    long steps = -1;
    for (long k = 0; k < maxSteps; k++) {
        mpfr_set_zero(x, 1);
        mpfr_set_zero(y, 1);
        mpfr_set_zero(dx, 1);
        mpfr_set_zero(dy, 1);
        for (long i = 0; i < period; i++) {
            // dz = 2 z dz + 1
            mpfr_mul(t0, x, dx, MPFR_RNDN);
            mpfr_mul(t1, y, dy, MPFR_RNDN);
            mpfr_sub(nx, t0, t1, MPFR_RNDN);
            mpfr_mul(t0, x, dy, MPFR_RNDN);
            mpfr_mul(t1, y, dx, MPFR_RNDN);
            mpfr_add(ny, t0, t1, MPFR_RNDN);
            mpfr_mul_2ui(nx, nx, 1, MPFR_RNDN);
            mpfr_mul_2ui(ny, ny, 1, MPFR_RNDN);
            mpfr_add_ui(dx, nx, 1, MPFR_RNDN);
            mpfr_set(dy, ny, MPFR_RNDN);
            // z = z^2 + c
            mpfr_sqr(t0, x, MPFR_RNDN);
            mpfr_sqr(t1, y, MPFR_RNDN);
            mpfr_mul(t2, x, y, MPFR_RNDN);
            mpfr_mul_2ui(t2, t2, 1, MPFR_RNDN);
            mpfr_sub(x, t0, t1, MPFR_RNDN);
            mpfr_add(x, x, cx, MPFR_RNDN);
            mpfr_add(y, t2, cy, MPFR_RNDN);
        }
        // c -= z / dz
        mpfr_sqr(t0, dx, MPFR_RNDN);
        mpfr_sqr(t1, dy, MPFR_RNDN);
        mpfr_add(den, t0, t1, MPFR_RNDN);
        if (mpfr_zero_p(den)) break;
        mpfr_mul(t0, x, dx, MPFR_RNDN);
        mpfr_mul(t1, y, dy, MPFR_RNDN);
        mpfr_add(nx, t0, t1, MPFR_RNDN);
        mpfr_mul(t0, y, dx, MPFR_RNDN);
        mpfr_mul(t1, x, dy, MPFR_RNDN);
        mpfr_sub(ny, t0, t1, MPFR_RNDN);
        mpfr_div(nx, nx, den, MPFR_RNDN);
        mpfr_div(ny, ny, den, MPFR_RNDN);
        mpfr_sub(cx, cx, nx, MPFR_RNDN);
        mpfr_sub(cy, cy, ny, MPFR_RNDN);
        steps = k + 1;
        // converged when the step is below the working precision relative to 1
        mpfr_hypot(t0, nx, ny, MPFR_RNDN);
        if (mpfr_zero_p(t0) || mpfr_get_exp(t0) < -(prec - 8)) break;
    }
    mpfr_set(outRe->value, cx, MPFR_RNDN);
    mpfr_set(outIm->value, cy, MPFR_RNDN);
    mpfr_clears(cx, cy, x, y, dx, dy, t0, t1, t2, nx, ny, den, (mpfr_ptr)0);
    return steps;
}

// Extended-range complex number (re + i im) * 2^e with max(|re|, |im|) in [0.5, 1), or zero.
typedef struct { double re, im; long e; } xcomplex;

static double scale2(double x, long k) { return k < -2000 ? 0 : ldexp(x, (int)k); }

static xcomplex xc_norm(double re, double im, long e) {
    double m = fmax(fabs(re), fabs(im));
    if (m == 0) return (xcomplex){0, 0, 0};
    int k;
    frexp(m, &k);
    return (xcomplex){ldexp(re, -k), ldexp(im, -k), e + k};
}

static xcomplex xc_mul(xcomplex a, xcomplex b) { return xc_norm(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re, a.e + b.e); }

static xcomplex xc_add(xcomplex a, xcomplex b) {
    if (a.re == 0 && a.im == 0) return b;
    if (b.re == 0 && b.im == 0) return a;
    long e = a.e > b.e ? a.e : b.e;
    return xc_norm(scale2(a.re, a.e - e) + scale2(b.re, b.e - e), scale2(a.im, a.e - e) + scale2(b.im, b.e - e), e);
}

static xcomplex xc_div(xcomplex a, xcomplex b) {
    double d = b.re * b.re + b.im * b.im;
    return xc_norm((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d, a.e - b.e);
}

static xcomplex xc_from_mpfr(mpfr_t x, mpfr_t y) {
    long ex = 0, ey = 0;
    double mx = mpfr_zero_p(x) ? 0 : mpfr_get_d_2exp(&ex, x, MPFR_RNDN);
    double my = mpfr_zero_p(y) ? 0 : mpfr_get_d_2exp(&ey, y, MPFR_RNDN);
    return xc_add(xc_norm(mx, 0, ex), xc_norm(0, my, ey));
}

static double xc_log2abs(xcomplex a) { return 0.5 * log2(a.re * a.re + a.im * a.im) + a.e; }

// Size and shape estimates of the minibrot with the given nucleus and period (after Heiland-Allen):
// it is approximately nucleus + s * M with s = 1 / (b l^2), where l is the product of 2 z_i and b the
// sum of 1 / partial products, i = 1 .. p-1. Returns log2 |s|, writes arg s (the rotation) to *angle
// and whether the component is a cardioid (a minibrot) rather than a disc (a bulb) to *cardioid.
double fs_nucleus_size(const FSHP *cre, const FSHP *cim, long period, double *angle, int *cardioid) {
    long prec = mpfr_get_prec(cre->value) + 16;
    mpfr_t x, y, t0, t1, t2, cx, cy;
    mpfr_inits2(prec, x, y, t0, t1, t2, cx, cy, (mpfr_ptr)0);
    mpfr_set(cx, cre->value, MPFR_RNDN);
    mpfr_set(cy, cim->value, MPFR_RNDN);
    mpfr_set_zero(x, 1);
    mpfr_set_zero(y, 1);
    const xcomplex one = xc_norm(1, 0, 0), two = xc_norm(2, 0, 0);
    xcomplex l = one, b = one, dc = one, dcdc = {0, 0, 0}, dcdz = {0, 0, 0};
    for (long i = 1; i < period; i++) {
        mpfr_sqr(t0, x, MPFR_RNDN);
        mpfr_sqr(t1, y, MPFR_RNDN);
        mpfr_mul(t2, x, y, MPFR_RNDN);
        mpfr_mul_2ui(t2, t2, 1, MPFR_RNDN);
        mpfr_sub(x, t0, t1, MPFR_RNDN);
        mpfr_add(x, x, cx, MPFR_RNDN);
        mpfr_add(y, t2, cy, MPFR_RNDN);
        xcomplex z = xc_from_mpfr(x, y);
        // derivatives of z_p with respect to c and z (dz equals l), for the shape estimate
        dcdc = xc_mul(two, xc_add(xc_mul(z, dcdc), xc_mul(dc, dc)));
        dcdz = xc_mul(two, xc_add(xc_mul(z, dcdz), xc_mul(dc, l)));
        dc = xc_add(xc_mul(xc_mul(two, z), dc), one);
        l = xc_mul(xc_mul(two, z), l);
        if (l.re == 0 && l.im == 0) break;
        b = xc_add(b, xc_div(one, l));
    }
    mpfr_clears(x, y, t0, t1, t2, cx, cy, (mpfr_ptr)0);
    // the shape -(dcdc / (2 dc) + dcdz / dz) / (dc dz) is near 0 for cardioids and near 1 for discs
    xcomplex shape = xc_div(xc_add(xc_div(dcdc, xc_mul(two, dc)), xc_div(dcdz, l)), xc_mul(dc, l));
    double sr = -scale2(shape.re, shape.e), si = -scale2(shape.im, shape.e);
    *cardioid = sr * sr + si * si < (sr - 1) * (sr - 1) + si * si;
    *angle = -(atan2(b.im, b.re) + 2 * atan2(l.im, l.re));
    return -(xc_log2abs(b) + 2 * xc_log2abs(l));
}
