#include <mpfr.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "internal.h"

FSHP *fs_hp_new(long prec) {
    FSHP *h = malloc(sizeof *h);
    mpfr_init2(h->v, prec < MPFR_PREC_MIN ? MPFR_PREC_MIN : prec);
    mpfr_set_zero(h->v, 1);
    return h;
}

FSHP *fs_hp_clone(const FSHP *src, long prec) {
    FSHP *h = fs_hp_new(prec);
    mpfr_set(h->v, src->v, MPFR_RNDN);
    return h;
}

void fs_hp_free(FSHP *h) {
    if (!h) return;
    mpfr_clear(h->v);
    free(h);
}

long fs_hp_prec(const FSHP *h) { return (long)mpfr_get_prec(h->v); }

void fs_hp_set_prec(FSHP *h, long prec) {
    if (prec < MPFR_PREC_MIN) prec = MPFR_PREC_MIN;
    mpfr_prec_round(h->v, prec, MPFR_RNDN);
}

int fs_hp_set_str(FSHP *h, const char *s) { return mpfr_set_str(h->v, s, 10, MPFR_RNDN); }

void fs_hp_set(FSHP *h, const FSHP *src) { mpfr_set(h->v, src->v, MPFR_RNDN); }

void fs_hp_set_d(FSHP *h, double d) { mpfr_set_d(h->v, d, MPFR_RNDN); }

void fs_hp_add_2exp(FSHP *h, double m, long e) {
    if (m == 0) return;
    mpfr_t t;
    mpfr_init2(t, 64);
    mpfr_set_d(t, m, MPFR_RNDN);
    mpfr_mul_2si(t, t, e, MPFR_RNDN);
    mpfr_add(h->v, h->v, t, MPFR_RNDN);
    mpfr_clear(t);
}

double fs_hp_get_2exp(const FSHP *h, long *e) {
    if (mpfr_zero_p(h->v)) {
        *e = 0;
        return 0;
    }
    return mpfr_get_d_2exp(e, h->v, MPFR_RNDN);
}

double fs_hp_get_d(const FSHP *h) { return mpfr_get_d(h->v, MPFR_RNDN); }

double fs_hp_diff_2exp(const FSHP *a, const FSHP *b, long *e) {
    mpfr_prec_t p = mpfr_get_prec(a->v) > mpfr_get_prec(b->v) ? mpfr_get_prec(a->v) : mpfr_get_prec(b->v);
    mpfr_t t;
    mpfr_init2(t, p + 2);
    mpfr_sub(t, a->v, b->v, MPFR_RNDN);
    double r;
    if (mpfr_zero_p(t)) {
        *e = 0;
        r = 0;
    } else {
        r = mpfr_get_d_2exp(e, t, MPFR_RNDN);
    }
    mpfr_clear(t);
    return r;
}

void fs_hp_lerp(FSHP *out, const FSHP *a, const FSHP *b, double t) {
    mpfr_prec_t p = mpfr_get_prec(out->v);
    mpfr_t d;
    mpfr_init2(d, p + 2);
    mpfr_sub(d, b->v, a->v, MPFR_RNDN);
    mpfr_mul_d(d, d, t, MPFR_RNDN);
    mpfr_add(out->v, a->v, d, MPFR_RNDN);
    mpfr_clear(d);
}

char *fs_hp_to_str(const FSHP *h, int digits) {
    char *s = NULL;
    mpfr_asprintf(&s, "%.*Re", digits > 1 ? digits - 1 : 0, h->v);
    if (!s) return strdup("0");
    char *copy = strdup(s);
    mpfr_free_str(s);
    return copy;
}

void fs_free(void *p) { free(p); }
